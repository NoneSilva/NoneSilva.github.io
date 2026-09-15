#!/usr/bin/env escript
%%! -noshell
%% Copyright (c) 2026 Guilherme Silva. All rights reserved.
%% Catalog of one GitHub account's public contributions, as GitHub itself
%% counts them (contributionsCollection), collected month by month through
%% the authenticated `gh` CLI. Writes site/contributions.json and
%% site/contributions.js. Private repositories are never listed; the API
%% reports them only as a count, which is kept as meta.restricted.
-mode(compile).

-define(QUERY, <<
"query($login:String!, $from:DateTime!, $to:DateTime!, $prAfter:String, $issueAfter:String, $reviewAfter:String) {"
"  user(login:$login) { contributionsCollection(from:$from, to:$to) {"
"    restrictedContributionsCount"
"    commitContributionsByRepository(maxRepositories:100) {"
"      repository { nameWithOwner isPrivate url }"
"      contributions(first:100) { nodes { occurredAt commitCount } } }"
"    pullRequestContributions(first:100, after:$prAfter) {"
"      pageInfo { hasNextPage endCursor }"
"      nodes { occurredAt pullRequest { title url number state merged isDraft repository { nameWithOwner isPrivate url } } } }"
"    issueContributions(first:100, after:$issueAfter) {"
"      pageInfo { hasNextPage endCursor }"
"      nodes { occurredAt issue { title url number state stateReason repository { nameWithOwner isPrivate url } } } }"
"    pullRequestReviewContributions(first:100, after:$reviewAfter) {"
"      pageInfo { hasNextPage endCursor }"
"      nodes { occurredAt pullRequestReview { url state pullRequest { title url number repository { nameWithOwner isPrivate url } } } } }"
"  } } }">>).

main(Args) ->
    Opts = opts(Args, #{out => <<"contributions">>}),
    Viewer = viewer(),
    Login = maps:get(login, Opts, maps:get(<<"login">>, Viewer)),
    Since = case maps:get(since, Opts, undefined) of
                undefined -> ym(maps:get(<<"createdAt">>, Viewer));
                S -> ym(S)
            end,
    {{Y, M, _}, _} = calendar:universal_time(),
    Months = months(Since, {Y, M}),
    io:format("login ~s, ~B months from ~s~n", [Login, length(Months), fmt_ym(Since)]),
    %% Keyed by id across months: the API can return the same contribution
    %% in two adjacent windows around a month boundary.
    {ById, Restricted} =
        lists:foldl(
          fun({MY, MM}, {AccE, AccR}) ->
                  {E, R} = collect_month(Login, MY, MM),
                  io:format("  ~s: ~B public entries, ~B restricted~n", [fmt_ym({MY, MM}), length(E), R]),
                  {lists:foldl(fun(X, A) -> A#{maps:get(id, X) => X} end, AccE, E), AccR + R}
          end, {#{}, 0}, Months),
    Repos = lists:usort([maps:get(repo, E) || E <- maps:values(ById)]),
    %% Advisories: the global API cannot filter by credited user, but each
    %% repository lists its published advisories with credits. Look in every
    %% repository the account has contributed to.
    Advisories = lists:append([advisories(Login, R) || R <- Repos]),
    io:format("  advisories crediting ~s in ~B repositories: ~B~n", [Login, length(Repos), length(Advisories)]),
    %% The latest commit by the account in every repository it committed to:
    %% the "All" view shows that one commit instead of the monthly totals.
    CommitRepos = lists:usort([maps:get(repo, E) || E <- maps:values(ById), maps:get(type, E) =:= <<"commits">>]),
    Latest = lists:filtermap(fun(R) -> latest_commit(Login, R) end, CommitRepos),
    io:format("  latest commit found in ~B of ~B repositories~n", [length(Latest), length(CommitRepos)]),
    Sorted = lists:sort(fun(A, B) -> sort_key(A) >= sort_key(B) end, maps:values(ById) ++ Advisories ++ Latest),
    {Name, Links} = profile(Login),
    Meta = #{login => Login,
             name => Name,
             links => Links,
             since => fmt_ym(Since),
             generated => iso_now(),
             public => length(Sorted),
             repositories => length(Repos),
             restricted => Restricted,
             not_collected => []},
    Json = iolist_to_binary(json:encode(#{meta => Meta, entries => Sorted})),
    Out = maps:get(out, Opts),
    ok = filelib:ensure_dir(filename:join(Out, "x")),
    ok = file:write_file(filename:join(Out, "contributions.json"), Json),
    ok = file:write_file(filename:join(Out, "contributions.js"), [<<"window.CONTRIBUTIONS = ">>, Json, <<";\n">>]),
    io:format("wrote ~s/contributions.json: ~B public entries in ~B repositories, ~B restricted~n",
              [Out, length(Sorted), length(Repos), Restricted]).

%% ---- options -------------------------------------------------------------

opts(["--login", L | R], O) -> opts(R, O#{login => list_to_binary(L)});
opts(["--since", S | R], O) -> opts(R, O#{since => list_to_binary(S)});
opts(["--out", D | R], O) -> opts(R, O#{out => list_to_binary(D)});
opts([], O) -> O;
opts([X | _], _) -> io:format("unknown argument ~s~n", [X]), halt(2).

%% ---- collection ------------------------------------------------------------

viewer() ->
    D = graphql(<<"{ viewer { login createdAt } }">>, []),
    get([<<"data">>, <<"viewer">>], D).

%% Display name and links from the GitHub profile: the profile URL plus the
%% social accounts listed there (LinkedIn and the like), keyed by provider.
profile(Login) ->
    D = graphql(<<"query($login:String!) { user(login:$login) { name socialAccounts(first:10) { nodes { provider url } } } }">>,
                [{<<"login">>, Login}]),
    U = get([<<"data">>, <<"user">>], D),
    Name = case get([<<"name">>], U) of null -> Login; N -> N end,
    Nodes = get([<<"socialAccounts">>, <<"nodes">>], U),
    Links = lists:foldl(fun(N, Acc) -> Acc#{lower(get([<<"provider">>], N)) => get([<<"url">>], N)} end,
                        #{<<"github">> => <<"https://github.com/", Login/binary>>}, Nodes),
    {Name, Links}.

collect_month(Login, Y, M) ->
    From = fmt_day(Y, M),
    {NY, NM} = next({Y, M}),
    To = fmt_day(NY, NM),
    page(Login, From, To, #{pr => first, issue => first, review => first}, #{}, undefined).

page(Login, From, To, Cursors, Acc, Fixed) ->
    case lists:all(fun(V) -> V =:= done end, maps:values(Cursors)) of
        true ->
            {Commits, Restricted} = Fixed,
            {maps:values(Acc) ++ Commits, Restricted};
        false ->
            Vars = [{<<"login">>, Login}, {<<"from">>, From}, {<<"to">>, To} | cursor_vars(Cursors)],
            CC = get([<<"data">>, <<"user">>, <<"contributionsCollection">>], graphql(?QUERY, Vars)),
            Fixed1 = case Fixed of
                         undefined -> {commit_entries(Login, CC), get([<<"restrictedContributionsCount">>], CC)};
                         _ -> Fixed
                     end,
            {Acc1, Cursors1} =
                lists:foldl(fun(Kind, {A, C}) -> merge(Kind, CC, A, C) end,
                            {Acc, Cursors}, [pr, issue, review]),
            page(Login, From, To, Cursors1, Acc1, Fixed1)
    end.

cursor_vars(Cursors) ->
    [{var_name(K), C} || {K, C} <- maps:to_list(Cursors), is_binary(C)].

var_name(pr) -> <<"prAfter">>;
var_name(issue) -> <<"issueAfter">>;
var_name(review) -> <<"reviewAfter">>.

field(pr) -> <<"pullRequestContributions">>;
field(issue) -> <<"issueContributions">>;
field(review) -> <<"pullRequestReviewContributions">>.

merge(Kind, CC, Acc, Cursors) ->
    case maps:get(Kind, Cursors) of
        done -> {Acc, Cursors};
        _ ->
            L = get([field(Kind)], CC),
            Nodes = get([<<"nodes">>], L),
            Acc1 = lists:foldl(
                     fun(N, A) ->
                             case entry(Kind, N) of
                                 skip -> A;
                                 E -> A#{maps:get(id, E) => E}
                             end
                     end, Acc, Nodes),
            PI = get([<<"pageInfo">>], L),
            Next = case get([<<"hasNextPage">>], PI) of
                       true -> get([<<"endCursor">>], PI);
                       false -> done
                   end,
            {Acc1, Cursors#{Kind => Next}}
    end.

entry(pr, N) ->
    P = get([<<"pullRequest">>], N),
    Repo = get([<<"repository">>], P),
    case get([<<"isPrivate">>], Repo) of
        true -> skip;
        false ->
            State = case {get([<<"merged">>], P), get([<<"isDraft">>], P), lower(get([<<"state">>], P))} of
                        {true, _, _} -> <<"merged">>;
                        {false, true, <<"open">>} -> <<"draft">>;
                        {false, _, S} -> S
                    end,
            Number = get([<<"number">>], P),
            RepoName = get([<<"nameWithOwner">>], Repo),
            #{id => id([<<"pr">>, RepoName, integer_to_binary(Number)]),
              type => <<"pr">>,
              date => day(get([<<"occurredAt">>], N)),
              repo => RepoName,
              repo_url => get([<<"url">>], Repo),
              number => Number,
              title => get([<<"title">>], P),
              url => get([<<"url">>], P),
              state => State}
    end;
entry(issue, N) ->
    I = get([<<"issue">>], N),
    Repo = get([<<"repository">>], I),
    case get([<<"isPrivate">>], Repo) of
        true -> skip;
        false ->
            Number = get([<<"number">>], I),
            RepoName = get([<<"nameWithOwner">>], Repo),
            #{id => id([<<"issue">>, RepoName, integer_to_binary(Number)]),
              type => <<"issue">>,
              date => day(get([<<"occurredAt">>], N)),
              repo => RepoName,
              repo_url => get([<<"url">>], Repo),
              number => Number,
              title => get([<<"title">>], I),
              url => get([<<"url">>], I),
              state => lower(get([<<"state">>], I)),
              reason => case get([<<"stateReason">>], I) of null -> null; R -> lower(R) end}
    end;
entry(review, N) ->
    R = get([<<"pullRequestReview">>], N),
    P = get([<<"pullRequest">>], R),
    Repo = get([<<"repository">>], P),
    case get([<<"isPrivate">>], Repo) of
        true -> skip;
        false ->
            Number = get([<<"number">>], P),
            RepoName = get([<<"nameWithOwner">>], Repo),
            Date = day(get([<<"occurredAt">>], N)),
            #{id => id([<<"review">>, RepoName, integer_to_binary(Number), Date]),
              type => <<"review">>,
              date => Date,
              repo => RepoName,
              repo_url => get([<<"url">>], Repo),
              number => Number,
              title => get([<<"title">>], P),
              url => get([<<"url">>], R),
              state => lower(get([<<"state">>], R))}
    end.

commit_entries(Login, CC) ->
    lists:filtermap(
      fun(R) ->
              Repo = get([<<"repository">>], R),
              Nodes = get([<<"contributions">>, <<"nodes">>], R),
              case get([<<"isPrivate">>], Repo) orelse Nodes =:= [] of
                  true -> false;
                  false ->
                      Count = lists:sum([get([<<"commitCount">>], X) || X <- Nodes]),
                      Last = lists:max([day(get([<<"occurredAt">>], X)) || X <- Nodes]),
                      RepoName = get([<<"nameWithOwner">>], Repo),
                      RepoUrl = get([<<"url">>], Repo),
                      {true, #{id => id([<<"commits">>, RepoName, binary:part(Last, 0, 7)]),
                               type => <<"commits">>,
                               date => Last,
                               repo => RepoName,
                               repo_url => RepoUrl,
                               number => null,
                               title => <<(integer_to_binary(Count))/binary, " commits">>,
                               url => <<RepoUrl/binary, "/commits?author=", Login/binary>>,
                               state => <<"pushed">>,
                               count => Count}}
              end
      end, get([<<"commitContributionsByRepository">>], CC)).

advisories(Login, Repo) ->
    case gh([<<"api">>, <<"repos/", Repo/binary, "/security-advisories?per_page=100">>]) of
        {ok, Out} ->
            lists:filtermap(
              fun(A) ->
                      Credited = [C || C <- maps:get(<<"credits">>, A, []), maps:get(<<"login">>, C, null) =:= Login],
                      case Credited =/= [] andalso maps:get(<<"state">>, A) =:= <<"published">> of
                          false -> false;
                          true ->
                              Ghsa = get([<<"ghsa_id">>], A),
                              {true, #{id => id([<<"advisory">>, Repo, Ghsa]),
                                       type => <<"advisory">>,
                                       date => day(get([<<"published_at">>], A)),
                                       repo => Repo,
                                       repo_url => <<"https://github.com/", Repo/binary>>,
                                       number => Ghsa,
                                       title => get([<<"summary">>], A),
                                       url => get([<<"html_url">>], A),
                                       state => lower(get([<<"severity">>], A)),
                                       credit => lower(get([<<"type">>], hd(Credited)))}}
                      end
              end, json:decode(Out));
        {error, _, _} ->
            []   %% no access or advisories disabled for this repository
    end.

latest_commit(Login, Repo) ->
    case gh([<<"api">>, <<"repos/", Repo/binary, "/commits?author=", Login/binary, "&per_page=1">>]) of
        {ok, Out} ->
            case json:decode(Out) of
                [C | _] ->
                    Sha = get([<<"sha">>], C),
                    Short = binary:part(Sha, 0, 7),
                    Date = day(get([<<"commit">>, <<"committer">>, <<"date">>], C)),
                    {true, #{id => id([<<"commit">>, Repo, Short]),
                             type => <<"commit">>,
                             date => Date,
                             repo => Repo,
                             repo_url => <<"https://github.com/", Repo/binary>>,
                             number => Short,
                             title => <<"Show commits">>,
                             %% The link opens all of the account's commits in the
                             %% repository, not this one commit.
                             url => <<"https://github.com/", Repo/binary, "/commits?author=", Login/binary>>,
                             state => <<"latest">>}};
                _ -> false
            end;
        {error, _, _} -> false
    end.

%% ---- gh --------------------------------------------------------------------

graphql(Query, Vars) ->
    Args = [<<"api">>, <<"graphql">>, <<"-f">>, <<"query=", Query/binary>>
            | lists:append([[<<"-f">>, <<K/binary, "=", V/binary>>] || {K, V} <- Vars])],
    case gh(Args) of
        {ok, Out} ->
            D = json:decode(Out),
            case maps:get(<<"errors">>, D, []) of
                [] -> D;
                Errs -> io:format("graphql errors: ~p~n", [Errs]), halt(1)
            end;
        {error, Status, Out} ->
            io:format("gh exited ~B:~n~s~n", [Status, Out]), halt(1)
    end.

gh(Args) ->
    Exe = case os:find_executable("gh") of
              false -> io:format("gh not found in PATH~n"), halt(1);
              P -> P
          end,
    Port = open_port({spawn_executable, Exe},
                     [{args, Args}, binary, exit_status, stream, use_stdio, stderr_to_stdout]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, D}} -> collect(Port, <<Acc/binary, D/binary>>);
        {Port, {exit_status, 0}} -> {ok, Acc};
        {Port, {exit_status, S}} -> {error, S, Acc}
    end.

%% ---- helpers -----------------------------------------------------------------

get([], V) -> V;
get([K | Ks], M) when is_map(M) -> get(Ks, maps:get(K, M));
get(Ks, V) -> error({path, Ks, V}).

lower(B) -> string:lowercase(B).

day(Iso) -> binary:part(Iso, 0, 10).

id(Parts) ->
    Joined = lists:join(<<"-">>, Parts),
    B = iolist_to_binary(Joined),
    binary:replace(lower(B), [<<"/">>, <<".">>], <<"-">>, [global]).

sort_key(E) -> {maps:get(date, E), rank(maps:get(type, E)), maps:get(id, E)}.

rank(<<"advisory">>) -> 5;
rank(<<"pr">>) -> 4;
rank(<<"issue">>) -> 3;
rank(<<"review">>) -> 2;
rank(<<"commit">>) -> 1;
rank(<<"commits">>) -> 0.

ym(<<Y:4/binary, "-", M:2/binary, _/binary>>) -> {binary_to_integer(Y), binary_to_integer(M)}.

fmt_ym({Y, M}) -> iolist_to_binary(io_lib:format("~4..0B-~2..0B", [Y, M])).

fmt_day(Y, M) -> iolist_to_binary(io_lib:format("~4..0B-~2..0B-01T00:00:00Z", [Y, M])).

next({Y, 12}) -> {Y + 1, 1};
next({Y, M}) -> {Y, M + 1}.

months(From, To) when From > To -> [];
months(From, To) -> [From | months(next(From), To)].

iso_now() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y, Mo, D, H, Mi, S])).
