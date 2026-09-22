#!/usr/bin/env escript
%%! -noshell
%% Copyright (c) 2026 Guilherme Silva. All rights reserved.
%% A stand-in for the `gh` CLI, used by tools/test_catalog.escript: answers
%% the calls tools/catalog.escript makes from a hand-written dataset and
%% never touches the network. Environment:
%%   CATALOG_FAKE_DATA        dataset file, Erlang terms (see test_catalog.escript)
%%   CATALOG_FAKE_LOG         file appended with one `{Kind, StartMs, EndMs}.` per call
%%   CATALOG_FAKE_DELAY_MS    time every call takes, so that overlap can be observed
%%   CATALOG_FAKE_MAX_MONTHS  windows spanning more months are rejected, as the
%%                            API rejects more than one year (default 12)
-mode(compile).

-define(PAGE, 100).

main(Args) ->
    Start = os:system_time(millisecond),
    {ok, Data} = file:consult(os:getenv("CATALOG_FAKE_DATA")),
    timer:sleep(list_to_integer(os:getenv("CATALOG_FAKE_DELAY_MS", "0"))),
    {Kind, Status, Body} = answer(Args, Data),
    ok = file:write_file(os:getenv("CATALOG_FAKE_LOG"),
                         io_lib:format("~p.~n", [{Kind, Start, os:system_time(millisecond)}]), [append]),
    io:format("~s", [Body]),
    halt(Status).

answer(["api", "graphql" | Flags], Data) ->
    Vars = vars(Flags),
    Query = maps:get(<<"query">>, Vars),
    case {has(Query, "contributionsCollection"), has(Query, "history("), has(Query, "viewer")} of
        {true, _, _} -> window(Vars, Data);
        {_, true, _} -> latest(Vars, Data);
        {_, _, true} -> {account, 0, json(#{data => #{viewer => account(Data, undefined)}})};
        _ -> {account, 0, json(#{data => #{user => account(Data, maps:get(<<"login">>, Vars))}})}
    end;
answer(["api", Path], Data) ->
    ["repos", Owner, Name, ResourceQuery] = string:split(Path, "/", all),
    [Resource | _] = string:split(ResourceQuery, "?"),
    rest(Resource, iolist_to_binary([Owner, "/", Name]), Data).

vars(["-f", KV | Rest]) ->
    [K, V] = binary:split(list_to_binary(KV), <<"=">>),
    (vars(Rest))#{K => V};
vars([]) ->
    #{}.

has(Query, Text) -> string:find(Query, Text) =/= nomatch.

%% ---- account ---------------------------------------------------------------

account(Data, Login) ->
    [{account, L, CreatedAt, Id, Name, Social}] = [A || A = {account, _, _, _, _, _} <- Data],
    #{login => case Login of undefined -> L; _ -> Login end,
      createdAt => CreatedAt, id => Id, name => Name,
      socialAccounts => #{nodes => [#{provider => P, url => U} || {P, U} <- Social]}}.

%% ---- contributionsCollection -------------------------------------------------

window(Vars, Data) ->
    From = maps:get(<<"from">>, Vars),
    To = maps:get(<<"to">>, Vars),
    Kind = {window, From, To},
    Max = list_to_integer(os:getenv("CATALOG_FAKE_MAX_MONTHS", "12")),
    case months_spanned(From, To) > Max of
        true ->
            {Kind, 1, [json(#{data => null, errors => [#{message => <<"The total time spanned by 'from' and 'to' must not exceed 1 year">>}]}),
                       "\ngh: The total time spanned by 'from' and 'to' must not exceed 1 year\n"]};
        false ->
            In = fun(At) -> At >= From andalso At =< To end,
            Prs = lists:keysort(4, [P || P = {pr, _, _, At, _, _} <- Data, In(At)]),
            Issues = lists:keysort(4, [I || I = {issue, _, _, At, _, _, _} <- Data, In(At)]),
            Reviews = lists:keysort(4, [R || R = {review, _, _, At, _, _} <- Data, In(At)]),
            Commits = [C || C = {commits, _, Day, _} <- commits(Data), In(<<Day/binary, "T00:00:00Z">>)],
            Private = fun(Repo) -> private(Repo, Data) end,
            Restricted = length([x || {pr, R, _, _, _, _} <- Prs, Private(R)])
                         + length([x || {issue, R, _, _, _, _, _} <- Issues, Private(R)])
                         + length([x || {review, R, _, _, _, _} <- Reviews, Private(R)])
                         + lists:sum([N || {commits, R, _, N} <- Commits, Private(R)]),
            CC = #{restrictedContributionsCount => Restricted,
                   commitContributionsByRepository => by_repository(Commits, Data),
                   pullRequestContributions => page([pr_node(P, Data) || P <- Prs], <<"prAfter">>, Vars),
                   issueContributions => page([issue_node(I, Data) || I <- Issues], <<"issueAfter">>, Vars),
                   pullRequestReviewContributions => page([review_node(R, Data) || R <- Reviews], <<"reviewAfter">>, Vars)},
            {Kind, 0, json(#{data => #{user => #{contributionsCollection => CC}}})}
    end.

months_spanned(<<Y1:4/binary, "-", M1:2/binary, _/binary>>, <<Y2:4/binary, "-", M2:2/binary, _/binary>>) ->
    (binary_to_integer(Y2) - binary_to_integer(Y1)) * 12 + binary_to_integer(M2) - binary_to_integer(M1) + 1.

%% Hand-written commit days plus the bulk ones: N repositories named
%% Prefix001.., each with one commit day. Enough repositories to go over
%% the API's cap without listing them one by one.
commits(Data) ->
    [C || C = {commits, _, _, _} <- Data]
    ++ lists:append([[{commits, iolist_to_binary(io_lib:format("~s~3..0B", [Prefix, I])), Day, Count} || I <- lists:seq(1, N)]
                     || {bulk_commits, Prefix, N, Day, Count} <- Data]).

private(Repo, Data) ->
    lists:member({repo, Repo, private}, Data).

repository(Repo, Data) ->
    #{nameWithOwner => Repo, isPrivate => private(Repo, Data), url => <<"https://github.com/", Repo/binary>>}.

%% The API's shape: at most 100 repositories, each with at most 100 days
%% and a pageInfo saying whether more days exist.
by_repository(Commits, Data) ->
    Repos = lists:sublist(lists:usort([R || {commits, R, _, _} <- Commits]), ?PAGE),
    [begin
         Days = lists:keysort(3, [C || C = {commits, R0, _, _} <- Commits, R0 =:= R]),
         #{repository => repository(R, Data),
           contributions => #{pageInfo => #{hasNextPage => length(Days) > ?PAGE},
                              nodes => [#{occurredAt => <<Day/binary, "T00:00:00Z">>, commitCount => Count}
                                        || {commits, _, Day, Count} <- lists:sublist(Days, ?PAGE)]}}
     end || R <- Repos].

%% Cursor-paginated connection: the cursor is the offset of the next page.
page(Nodes, CursorVar, Vars) ->
    Offset = binary_to_integer(maps:get(CursorVar, Vars, <<"0">>)),
    HasNext = Offset + ?PAGE < length(Nodes),
    #{pageInfo => #{hasNextPage => HasNext,
                    endCursor => case HasNext of true -> integer_to_binary(Offset + ?PAGE); false -> null end},
      nodes => lists:sublist(Nodes, Offset + 1, ?PAGE)}.

pr_node({pr, Repo, Number, At, Title, State}, Data) ->
    {ApiState, Merged, Draft} = case State of
                                    merged -> {<<"MERGED">>, true, false};
                                    open -> {<<"OPEN">>, false, false};
                                    draft -> {<<"OPEN">>, false, true};
                                    closed -> {<<"CLOSED">>, false, false}
                                end,
    #{occurredAt => At,
      pullRequest => #{title => Title, url => url(Repo, "pull", Number), number => Number,
                       state => ApiState, merged => Merged, isDraft => Draft,
                       repository => repository(Repo, Data)}}.

issue_node({issue, Repo, Number, At, Title, State, Reason}, Data) ->
    #{occurredAt => At,
      issue => #{title => Title, url => url(Repo, "issues", Number), number => Number,
                 state => string:uppercase(atom_to_binary(State)),
                 stateReason => case Reason of null -> null; _ -> string:uppercase(atom_to_binary(Reason)) end,
                 repository => repository(Repo, Data)}}.

review_node({review, Repo, Number, At, Title, State}, Data) ->
    #{occurredAt => At,
      pullRequestReview => #{url => <<(url(Repo, "pull", Number))/binary, "#pullrequestreview-1">>,
                             state => string:uppercase(atom_to_binary(State)),
                             pullRequest => #{title => Title, url => url(Repo, "pull", Number), number => Number,
                                              repository => repository(Repo, Data)}}}.

url(Repo, Kind, Number) ->
    iolist_to_binary(["https://github.com/", Repo, "/", Kind, "/", integer_to_binary(Number)]).

%% ---- latest commits, one alias per repository ----------------------------------

latest(Vars, Data) ->
    Indexes = lists:sort([binary_to_integer(I) || <<"o", I/binary>> <- maps:keys(Vars)]),
    Aliases = [begin
                   Repo = <<(maps:get(<<"o", (integer_to_binary(I))/binary>>, Vars))/binary, "/",
                            (maps:get(<<"n", (integer_to_binary(I))/binary>>, Vars))/binary>>,
                   Value = case [L || L = {latest, R, _, _} <- Data, R =:= Repo] of
                               [{latest, _, Sha, At}] ->
                                   #{defaultBranchRef => #{target => #{history => #{nodes => [#{oid => Sha, committedDate => At}]}}}};
                               [] ->
                                   #{defaultBranchRef => null}
                           end,
                   {<<"r", (integer_to_binary(I))/binary>>, Value}
               end || I <- Indexes],
    {{latest, length(Indexes)}, 0, json(#{data => maps:from_list(Aliases)})}.

%% ---- REST --------------------------------------------------------------------

rest("security-advisories", Repo, Data) ->
    case lists:member({advisories_forbidden, Repo}, Data) of
        true ->
            {{advisories, Repo}, 1, "gh: HTTP 403: Resource not accessible by integration\n"};
        false ->
            {{advisories, Repo}, 0,
             json([#{ghsa_id => Ghsa, summary => Summary, state => atom_to_binary(State), published_at => At,
                     html_url => <<"https://github.com/", Repo/binary, "/security/advisories/", Ghsa/binary>>,
                     severity => atom_to_binary(Severity),
                     credits => [#{login => L, type => atom_to_binary(T)} || {L, T} <- Credits]}
                   || {advisory, R, Ghsa, At, State, Severity, Summary, Credits} <- Data, R =:= Repo])}
    end;
rest("commits", Repo, Data) ->
    {{commits, Repo}, 0,
     json([#{sha => Sha, commit => #{committer => #{date => At}}} || {latest, R, Sha, At} <- Data, R =:= Repo])}.

json(Term) -> json:encode(Term).
