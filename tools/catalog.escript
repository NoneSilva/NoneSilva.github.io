#!/usr/bin/env escript
%%! -noshell
%% Copyright (c) 2026 Guilherme Silva. All rights reserved.
%% Catalog of one GitHub account's public contributions, as GitHub itself
%% counts them (contributionsCollection), collected in windows of up to
%% twelve months through the authenticated `gh` CLI. Writes
%% site/contributions.json and site/contributions.js. Private repositories
%% are never listed; the API reports them only as a count, which is kept as
%% meta.restricted.
%%
%% Calls that do not depend on each other run at the same time, at most
%% ?MAX_CONCURRENT at once. Three waits remain because the data imposes
%% them: the account (login, creation date, id) before the windows; every
%% window before the per-repository lookups, which need the list of
%% repositories; every lookup before the files are written.
-mode(compile).

%% contributionsCollection accepts a span of at most one year.
-define(WINDOW_MONTHS, 12).
%% GitHub rejects more than 100 concurrent requests from one account.
-define(MAX_CONCURRENT, 8).
%% Repositories per latest-commit query: one alias each in one document.
-define(LATEST_BATCH, 50).
%% Largest page the API serves, and its cap on repositories with commits.
-define(PAGE, 100).

-define(QUERY, <<
"query($login:String!, $from:DateTime!, $to:DateTime!, $prAfter:String, $issueAfter:String, $reviewAfter:String) {"
"  user(login:$login) { contributionsCollection(from:$from, to:$to) {"
"    restrictedContributionsCount"
"    commitContributionsByRepository(maxRepositories:100) {"
"      repository { nameWithOwner isPrivate url }"
"      contributions(first:100) { pageInfo { hasNextPage } nodes { occurredAt commitCount } } }"
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

-define(ACCOUNT, "login createdAt id name socialAccounts(first:10) { nodes { provider url } }").

main(Args) ->
    Opts = opts(Args, #{out => <<"contributions">>}),
    Account = account(maps:get(login, Opts, undefined)),
    Login = get([<<"login">>], Account),
    Since = case maps:get(since, Opts, undefined) of
                undefined -> ym(get([<<"createdAt">>], Account));
                S -> ym(S)
            end,
    {{Y, M, _}, _} = calendar:universal_time(),
    Windows = chunks(?WINDOW_MONTHS, months(Since, {Y, M})),
    io:format("login ~s, ~B windows from ~s~n", [Login, length(Windows), fmt_ym(Since)]),
    Collected = pmap(fun(W) -> collect_window(Login, W) end, Windows),
    %% Keyed by id across windows: the API can return the same contribution
    %% in two adjacent windows around a boundary.
    {ById, Restricted} =
        lists:foldl(fun({E, R}, {AccE, AccR}) ->
                            {lists:foldl(fun(X, A) -> A#{maps:get(id, X) => X} end, AccE, E), AccR + R}
                    end, {#{}, 0}, Collected),
    Repos = lists:usort([maps:get(repo, E) || E <- maps:values(ById)]),
    CommitRepos = lists:usort([maps:get(repo, E) || E <- maps:values(ById), maps:get(type, E) =:= <<"commits">>]),
    %% Advisories: the global API cannot filter by credited user, but each
    %% repository lists its published advisories with credits. Look in every
    %% repository the account has contributed to. Latest commit: the one the
    %% "All" view shows instead of the monthly totals, in every repository
    %% the account committed to. Both need only the lists above, so they run
    %% together.
    Lookups = [{advisories, R} || R <- Repos]
              ++ [{latest, Batch} || Batch <- chunks(?LATEST_BATCH, CommitRepos)],
    Found = lists:zip(Lookups,
                      pmap(fun({advisories, R}) -> advisories(Login, R);
                              ({latest, Batch}) -> latest_commits(get([<<"id">>], Account), Login, Batch)
                           end, Lookups)),
    Advisories = lists:append([E || {{advisories, _}, E} <- Found]),
    Latest = lists:append([E || {{latest, _}, E} <- Found]),
    io:format("  advisories crediting ~s in ~B repositories: ~B~n", [Login, length(Repos), length(Advisories)]),
    io:format("  latest commit found in ~B of ~B repositories~n", [length(Latest), length(CommitRepos)]),
    Sorted = lists:sort(fun(A, B) -> sort_key(A) >= sort_key(B) end, maps:values(ById) ++ Advisories ++ Latest),
    Meta = #{login => Login,
             name => case get([<<"name">>], Account) of null -> Login; N -> N end,
             links => links(Login, Account),
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
    stamp_page(Out),
    io:format("wrote ~s/contributions.json: ~B public entries in ~B repositories, ~B restricted~n",
              [Out, length(Sorted), length(Repos), Restricted]).

%% Cache busting: the page loads the data file with a version query string
%% carrying the generation time, so a fresh page never pairs with a data
%% file still held in a visitor's cache. GitHub Pages caches for 10 minutes.
stamp_page(Out) ->
    Page = filename:join(filename:dirname(Out), "index.html"),
    case file:read_file(Page) of
        {ok, Html} ->
            Stamp = integer_to_binary(erlang:system_time(second)),
            New = re:replace(Html, <<"contributions/contributions\\.js(\\?v=[0-9]+)?">>,
                             <<"contributions/contributions.js?v=", Stamp/binary>>, [{return, binary}]),
            ok = file:write_file(Page, New);
        _ -> ok
    end.

%% ---- options -------------------------------------------------------------

opts(["--login", L | R], O) -> opts(R, O#{login => list_to_binary(L)});
opts(["--since", S | R], O) -> opts(R, O#{since => list_to_binary(S)});
opts(["--out", D | R], O) -> opts(R, O#{out => list_to_binary(D)});
opts([], O) -> O;
opts([X | _], _) -> io:format("unknown argument ~s~n", [X]), halt(2).

%% ---- account -------------------------------------------------------------

%% Login, creation date, node id, display name and social accounts: of the
%% authenticated account, or of the given login.
account(undefined) ->
    get([<<"data">>, <<"viewer">>], graphql(<<"{ viewer { " ?ACCOUNT " } }">>, []));
account(Login) ->
    get([<<"data">>, <<"user">>],
        graphql(<<"query($login:String!) { user(login:$login) { " ?ACCOUNT " } }">>, [{<<"login">>, Login}])).

%% Header links: the profile URL plus the social accounts listed on the
%% profile (LinkedIn and the like), keyed by provider.
links(Login, Account) ->
    lists:foldl(fun(N, Acc) -> Acc#{lower(get([<<"provider">>], N)) => get([<<"url">>], N)} end,
                #{<<"github">> => <<"https://github.com/", Login/binary>>},
                get([<<"socialAccounts">>, <<"nodes">>], Account)).

%% ---- collection ------------------------------------------------------------

%% One window of consecutive months. The first page tells whether the
%% window fits the API's caps (100 repositories with commits, 100 commit
%% days per repository). Over the caps, or rejected by the API, the window
%% is split in half and each half collected again, down to single months.
%% A month is never split, so every "N commits" row is one whole month.
collect_window(Login, Months) ->
    Label = window_label(Months),
    {From, To} = span(Months),
    case query_window(Login, From, To, first_cursors()) of
        {ok, CC} ->
            case truncated(CC) of
                true when length(Months) > 1 ->
                    io:format("  ~s: over the API caps, splitting~n", [Label]),
                    split_window(Login, Months);
                Truncated ->
                    case Truncated of
                        true -> io:format("  ~s: over the API caps in one month, commits are missing~n", [Label]);
                        false -> ok
                    end,
                    {Acc, Cursors} = merge_kinds(CC, #{}, first_cursors()),
                    Entries = maps:values(pages(Login, From, To, Cursors, Acc)) ++ commit_entries(Login, CC),
                    Restricted = get([<<"restrictedContributionsCount">>], CC),
                    io:format("  ~s: ~B public entries, ~B restricted~n", [Label, length(Entries), Restricted]),
                    {Entries, Restricted}
            end;
        {error, Out} when length(Months) > 1 ->
            io:format("  ~s: rejected, splitting~n~s~n", [Label, Out]),
            split_window(Login, Months);
        {error, Out} ->
            io:format("  ~s: ~s~n", [Label, Out]),
            halt(1)
    end.

split_window(Login, Months) ->
    {A, B} = lists:split(length(Months) div 2, Months),
    {EA, RA} = collect_window(Login, A),
    {EB, RB} = collect_window(Login, B),
    {EA ++ EB, RA + RB}.

%% The first day of the first month to the last second of the last month.
span(Months) ->
    {Y1, M1} = hd(Months),
    {Y2, M2} = lists:last(Months),
    {iolist_to_binary(io_lib:format("~4..0B-~2..0B-01T00:00:00Z", [Y1, M1])),
     iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT23:59:59Z", [Y2, M2, calendar:last_day_of_the_month(Y2, M2)]))}.

window_label([Month]) -> fmt_ym(Month);
window_label(Months) -> <<(fmt_ym(hd(Months)))/binary, "..", (fmt_ym(lists:last(Months)))/binary>>.

first_cursors() -> #{pr => first, issue => first, review => first}.

truncated(CC) ->
    ByRepo = get([<<"commitContributionsByRepository">>], CC),
    length(ByRepo) >= ?PAGE
        orelse lists:any(fun(R) -> get([<<"contributions">>, <<"pageInfo">>, <<"hasNextPage">>], R) end, ByRepo).

query_window(Login, From, To, Cursors) ->
    Vars = [{<<"login">>, Login}, {<<"from">>, From}, {<<"to">>, To} | cursor_vars(Cursors)],
    case graphql_result(?QUERY, Vars) of
        {ok, D} -> {ok, get([<<"data">>, <<"user">>, <<"contributionsCollection">>], D)};
        Error -> Error
    end.

%% Remaining pages of the pull request, issue and review connections. Each
%% kind advances its own cursor; a kind whose last page has been read is
%% `done` and ignored in the answers that follow.
pages(Login, From, To, Cursors, Acc) ->
    case lists:all(fun(V) -> V =:= done end, maps:values(Cursors)) of
        true -> Acc;
        false ->
            CC = case query_window(Login, From, To, Cursors) of
                     {ok, C} -> C;
                     {error, Out} -> io:format("~s~n", [Out]), halt(1)
                 end,
            {Acc1, Cursors1} = merge_kinds(CC, Acc, Cursors),
            pages(Login, From, To, Cursors1, Acc1)
    end.

merge_kinds(CC, Acc, Cursors) ->
    lists:foldl(fun(Kind, {A, C}) -> merge(Kind, CC, A, C) end, {Acc, Cursors}, [pr, issue, review]).

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
              at => get([<<"occurredAt">>], N),
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
              at => get([<<"occurredAt">>], N),
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
              at => get([<<"occurredAt">>], N),
              date => Date,
              repo => RepoName,
              repo_url => get([<<"url">>], Repo),
              number => Number,
              title => get([<<"title">>], P),
              url => get([<<"url">>], R),
              state => lower(get([<<"state">>], R))}
    end.

%% One "N commits" entry per public repository per calendar month: the
%% commits counted in that month and the last day with one.
commit_entries(Login, CC) ->
    lists:flatmap(
      fun(R) ->
              Repo = get([<<"repository">>], R),
              Nodes = get([<<"contributions">>, <<"nodes">>], R),
              case get([<<"isPrivate">>], Repo) of
                  true -> [];
                  false ->
                      RepoName = get([<<"nameWithOwner">>], Repo),
                      RepoUrl = get([<<"url">>], Repo),
                      ByMonth = lists:foldl(
                                  fun(X, Acc) ->
                                          Day = day(get([<<"occurredAt">>], X)),
                                          Month = binary:part(Day, 0, 7),
                                          {Count, Last} = maps:get(Month, Acc, {0, Day}),
                                          Acc#{Month => {Count + get([<<"commitCount">>], X), max(Last, Day)}}
                                  end, #{}, Nodes),
                      [#{id => id([<<"commits">>, RepoName, Month]),
                         type => <<"commits">>,
                         date => Last,
                         repo => RepoName,
                         repo_url => RepoUrl,
                         number => null,
                         title => <<(integer_to_binary(Count))/binary, " commits">>,
                         url => <<RepoUrl/binary, "/commits?author=", Login/binary>>,
                         state => <<"pushed">>,
                         count => Count}
                       || {Month, {Count, Last}} <- maps:to_list(ByMonth)]
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
                                       at => get([<<"published_at">>], A),
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

%% The latest commit by the account on the default branch of each
%% repository, in one query: one alias per repository, the repository
%% names as variables. A repository with no such commit, or with no default
%% branch, yields nothing.
latest_commits(_UserId, _Login, []) ->
    [];
latest_commits(UserId, Login, Repos) ->
    Indexed = lists:zip(lists:seq(0, length(Repos) - 1), Repos),
    Decls = [io_lib:format(", $o~B:String!, $n~B:String!", [I, I]) || {I, _} <- Indexed],
    Fields = [io_lib:format(" r~B: repository(owner:$o~B, name:$n~B) { defaultBranchRef { target {"
                            " ... on Commit { history(first:1, author:{id:$uid}) { nodes { oid committedDate } } } } } }",
                            [I, I, I]) || {I, _} <- Indexed],
    Query = iolist_to_binary(["query($uid:ID!", Decls, ") {", Fields, " }"]),
    Vars = [{<<"uid">>, UserId}
            | lists:append([[{<<"o", (integer_to_binary(I))/binary>>, Owner},
                             {<<"n", (integer_to_binary(I))/binary>>, Name}]
                            || {I, R} <- Indexed, [Owner, Name] <- [binary:split(R, <<"/">>)]])],
    D = graphql(Query, Vars),
    lists:filtermap(
      fun({I, Repo}) ->
              case get([<<"data">>, <<"r", (integer_to_binary(I))/binary>>], D) of
                  #{<<"defaultBranchRef">> := #{<<"target">> := #{<<"history">> := #{<<"nodes">> := [C | _]}}}} ->
                      Sha = get([<<"oid">>], C),
                      Short = binary:part(Sha, 0, 7),
                      At = get([<<"committedDate">>], C),
                      {true, #{id => id([<<"commit">>, Repo, Short]),
                               type => <<"commit">>,
                               at => At,
                               date => day(At),
                               repo => Repo,
                               repo_url => <<"https://github.com/", Repo/binary>>,
                               number => Short,
                               title => <<"Latest commit">>,
                               %% The link opens all of the account's commits in the
                               %% repository, not this one commit.
                               url => <<"https://github.com/", Repo/binary, "/commits?author=", Login/binary>>,
                               state => <<"latest">>}};
                  _ -> false
              end
      end, Indexed).

%% ---- concurrency -----------------------------------------------------------

%% F applied to every element in its own process, at most ?MAX_CONCURRENT
%% at a time, results in the order of the list. A process that fails takes
%% the whole run down: partial output would read as a complete catalog.
pmap(F, L) ->
    pmap(F, lists:zip(lists:seq(1, length(L)), L), #{}, #{}).

pmap(_F, [], Running, Done) when map_size(Running) =:= 0 ->
    [R || {_, R} <- lists:keysort(1, maps:to_list(Done))];
pmap(F, [{I, X} | Pending], Running, Done) when map_size(Running) < ?MAX_CONCURRENT ->
    {_Pid, Ref} = spawn_monitor(fun() -> exit({result, F(X)}) end),
    pmap(F, Pending, Running#{Ref => I}, Done);
pmap(F, Pending, Running, Done) ->
    receive
        {'DOWN', Ref, process, _, {result, R}} when is_map_key(Ref, Running) ->
            {I, Running1} = maps:take(Ref, Running),
            pmap(F, Pending, Running1, Done#{I => R});
        {'DOWN', Ref, process, _, Reason} when is_map_key(Ref, Running) ->
            io:format("task ~B failed: ~p~n", [maps:get(Ref, Running), Reason]),
            halt(1)
    end.

chunks(_N, []) -> [];
chunks(N, L) when length(L) =< N -> [L];
chunks(N, L) -> {H, T} = lists:split(N, L), [H | chunks(N, T)].

%% ---- gh --------------------------------------------------------------------

graphql(Query, Vars) ->
    case graphql_result(Query, Vars) of
        {ok, D} -> D;
        {error, Out} -> io:format("~s~n", [Out]), halt(1)
    end.

%% {ok, Response} or {error, Text}: gh failing, or a response that carries
%% GraphQL errors.
graphql_result(Query, Vars) ->
    Args = [<<"api">>, <<"graphql">>, <<"-f">>, <<"query=", Query/binary>>
            | lists:append([[<<"-f">>, <<K/binary, "=", V/binary>>] || {K, V} <- Vars])],
    case gh(Args) of
        {ok, Out} ->
            D = json:decode(Out),
            case maps:get(<<"errors">>, D, []) of
                [] -> {ok, D};
                Errs -> {error, io_lib:format("graphql errors: ~p", [Errs])}
            end;
        {error, Status, Out} ->
            {error, io_lib:format("gh exited ~B:~n~s", [Status, Out])}
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

%% UTC calendar day of an ISO instant. Entries that happen at an instant
%% also carry the instant itself (`at`); the page shows it in the viewer's
%% time zone, as GitHub does. Commit days are GitHub's calendar days.
day(<<Ymd:10/binary, _/binary>>) -> Ymd.

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

next({Y, 12}) -> {Y + 1, 1};
next({Y, M}) -> {Y, M + 1}.

months(From, To) when From > To -> [];
months(From, To) -> [From | months(next(From), To)].

iso_now() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y, Mo, D, H, Mi, S])).
