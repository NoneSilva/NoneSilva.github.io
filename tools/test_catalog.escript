#!/usr/bin/env escript
%%! -noshell
%% Copyright (c) 2026 Guilherme Silva. All rights reserved.
%% Runs tools/catalog.escript against tools/fake_gh.escript, a stand-in for
%% `gh` that answers from the hand-written dataset below, and checks what
%% the generator writes and which calls it makes: how many, in what order,
%% and how many at a time. Everything happens in a temporary directory; the
%% repository is not touched. Usage:
%%   escript tools/test_catalog.escript      (from the repository root)
-mode(compile).

-define(ACCOUNT, {account, <<"nonesilva">>, <<"2025-10-05T12:00:00Z">>, <<"U_kgDOtest">>, <<"None Silva">>,
                  [{<<"LINKEDIN">>, <<"https://www.linkedin.com/in/nonesilva">>}]}).

%% Three public repositories, one private, a year of activity.
-define(DATASET, [
    ?ACCOUNT,
    {repo, <<"octo/alpha">>, public},
    {repo, <<"octo/beta">>, public},
    {repo, <<"octo/delta">>, public},
    {repo, <<"secret/gamma">>, private},
    {pr, <<"octo/alpha">>, 1, <<"2025-11-03T10:00:00Z">>, <<"Add alpha">>, merged},
    {pr, <<"octo/alpha">>, 2, <<"2026-02-10T09:30:00Z">>, <<"Draft thing">>, draft},
    {pr, <<"octo/beta">>, 7, <<"2026-05-20T15:00:00Z">>, <<"Fix beta">>, open},
    {pr, <<"secret/gamma">>, 3, <<"2026-01-01T00:00:00Z">>, <<"Private">>, merged},
    {issue, <<"octo/beta">>, 4, <<"2025-12-24T12:00:00Z">>, <<"Bug">>, closed, completed},
    {issue, <<"octo/alpha">>, 9, <<"2026-06-01T08:00:00Z">>, <<"Question">>, open, null},
    {issue, <<"octo/delta">>, 11, <<"2026-07-07T07:00:00Z">>, <<"Delta">>, open, null},
    {review, <<"octo/beta">>, 7, <<"2026-05-21T16:00:00Z">>, <<"Fix beta">>, approved},
    {commits, <<"octo/alpha">>, <<"2025-11-03">>, 3},
    {commits, <<"octo/alpha">>, <<"2025-11-20">>, 2},
    {commits, <<"octo/alpha">>, <<"2026-02-10">>, 1},
    {commits, <<"octo/beta">>, <<"2026-05-20">>, 4},
    {commits, <<"secret/gamma">>, <<"2026-03-03">>, 9},
    {advisory, <<"octo/alpha">>, <<"GHSA-aaaa-bbbb-cccc">>, <<"2026-04-15T00:00:00Z">>, published, high, <<"Alpha overflow">>,
     [{<<"nonesilva">>, reporter}]},
    {advisory, <<"octo/alpha">>, <<"GHSA-eeee-ffff-0000">>, <<"2026-04-16T00:00:00Z">>, draft, low, <<"Not yet">>,
     [{<<"nonesilva">>, reporter}]},
    {advisory, <<"octo/beta">>, <<"GHSA-dddd-1111-2222">>, <<"2026-04-17T00:00:00Z">>, published, medium, <<"Someone else">>,
     [{<<"someone">>, reporter}]},
    {advisories_forbidden, <<"octo/delta">>},
    {latest, <<"octo/alpha">>, <<"0123456789abcdef0123456789abcdef01234567">>, <<"2026-02-10T11:00:00Z">>}
]).

-define(EXPECTED_IDS, [
    <<"pr-octo-alpha-1">>, <<"pr-octo-alpha-2">>, <<"pr-octo-beta-7">>,
    <<"issue-octo-beta-4">>, <<"issue-octo-alpha-9">>, <<"issue-octo-delta-11">>,
    <<"review-octo-beta-7-2026-05-21">>,
    <<"commits-octo-alpha-2025-11">>, <<"commits-octo-alpha-2026-02">>, <<"commits-octo-beta-2026-05">>,
    <<"advisory-octo-alpha-ghsa-aaaa-bbbb-cccc">>,
    <<"commit-octo-alpha-0123456">>
]).

%% 120 repositories with commits in one year: over the API's cap of 100 per
%% window, so the generator has to split the window.
-define(BULK, [
    ?ACCOUNT,
    {bulk_commits, <<"octo/bulk-">>, 60, <<"2026-01-15">>, 1},
    {bulk_commits, <<"octo/more-">>, 60, <<"2026-03-15">>, 2}
]).

main(_) ->
    Root = filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    Tmp = filename:join(tmp_root(), "catalog-test-" ++ integer_to_list(erlang:system_time(microsecond))),
    Bin = filename:join(Tmp, "bin"),
    ok = filelib:ensure_dir(filename:join(Bin, "x")),
    ok = file:make_symlink(filename:join([Root, "tools", "fake_gh.escript"]), filename:join(Bin, "gh")),
    Ctx = #{root => Root, tmp => Tmp, bin => Bin},
    Windows = windows_since({2025, 10}),

    io:format("# basic run, calls delayed 150 ms so overlap shows~n"),
    R1 = run(Ctx, "basic", ?DATASET, [{"CATALOG_FAKE_DELAY_MS", "150"}], []),
    check("exits 0", maps:get(status, R1) =:= 0),
    J1 = maps:get(json, R1),
    Meta = get([<<"meta">>], J1),
    check("meta login/name/since", {get([<<"login">>], Meta), get([<<"name">>], Meta), get([<<"since">>], Meta)}
                                   =:= {<<"nonesilva">>, <<"None Silva">>, <<"2025-10">>}),
    check("meta counts: 12 public, 3 repositories, 10 restricted",
          {get([<<"public">>], Meta), get([<<"repositories">>], Meta), get([<<"restricted">>], Meta)} =:= {12, 3, 10}),
    check("meta links: github and linkedin",
          get([<<"links">>], Meta) =:= #{<<"github">> => <<"https://github.com/nonesilva">>,
                                         <<"linkedin">> => <<"https://www.linkedin.com/in/nonesilva">>}),
    Entries = get([<<"entries">>], J1),
    check("exactly the expected entries", lists:sort(ids(Entries)) =:= lists:sort(?EXPECTED_IDS)),
    check("sorted newest first", ids(Entries) =:= [<<"issue-octo-delta-11">>, <<"issue-octo-alpha-9">>,
                                                    <<"review-octo-beta-7-2026-05-21">>, <<"pr-octo-beta-7">>,
                                                    <<"commits-octo-beta-2026-05">>,
                                                    <<"advisory-octo-alpha-ghsa-aaaa-bbbb-cccc">>,
                                                    <<"pr-octo-alpha-2">>, <<"commit-octo-alpha-0123456">>,
                                                    <<"commits-octo-alpha-2026-02">>, <<"issue-octo-beta-4">>,
                                                    <<"commits-octo-alpha-2025-11">>, <<"pr-octo-alpha-1">>]),
    Nov = entry(<<"commits-octo-alpha-2025-11">>, Entries),
    check("commits grouped per month: 3 + 2 on the last day with one",
          {get([<<"count">>], Nov), get([<<"title">>], Nov), get([<<"date">>], Nov)} =:= {5, <<"5 commits">>, <<"2025-11-20">>}),
    check("pr states", [get([<<"state">>], entry(I, Entries)) || I <- [<<"pr-octo-alpha-1">>, <<"pr-octo-alpha-2">>, <<"pr-octo-beta-7">>]]
                       =:= [<<"merged">>, <<"draft">>, <<"open">>]),
    check("issue reason", get([<<"reason">>], entry(<<"issue-octo-beta-4">>, Entries)) =:= <<"completed">>),
    Adv = entry(<<"advisory-octo-alpha-ghsa-aaaa-bbbb-cccc">>, Entries),
    check("advisory: severity as state, credit type", {get([<<"state">>], Adv), get([<<"credit">>], Adv)} =:= {<<"high">>, <<"reporter">>}),
    Lat = entry(<<"commit-octo-alpha-0123456">>, Entries),
    check("latest commit from the aliased query",
          {get([<<"date">>], Lat), get([<<"url">>], Lat)} =:= {<<"2026-02-10">>, <<"https://github.com/octo/alpha/commits?author=nonesilva">>}),
    {ok, Js} = file:read_file(filename:join(maps:get(out, R1), "contributions.js")),
    check("contributions.js wraps the same json", binary:part(Js, 0, 23) =:= <<"window.CONTRIBUTIONS = ">>),
    Calls = maps:get(calls, R1),
    check("one account call", count(account, Calls) =:= 1),
    check(io_lib:format("~B window call(s), one per window", [Windows]), count(window, Calls) =:= Windows),
    check("one advisories call per repository", count(advisories, Calls) =:= 3),
    check("one latest-commit call for both commit repositories", [N || {{latest, N}, _, _} <- Calls] =:= [2]),
    check("no REST commit calls", count(commits, Calls) =:= 0),
    check("account before windows", last_end(account, Calls) =< first_start(window, Calls)),
    check("windows before lookups", last_end(window, Calls) =< first_start(lookup, Calls)),
    check("lookups overlap", max_overlap([C || C <- Calls, class(C) =:= lookup]) >= 2),

    io:format("# --login and --since~n"),
    R2 = run(Ctx, "login", ?DATASET, [], ["--login", "other", "--since", "2026-05"]),
    check("exits 0", maps:get(status, R2) =:= 0),
    Meta2 = get([<<"meta">>], maps:get(json, R2)),
    check("meta from the given login and month", {get([<<"login">>], Meta2), get([<<"since">>], Meta2)} =:= {<<"other">>, <<"2026-05">>}),
    Ids2 = ids(get([<<"entries">>], maps:get(json, R2))),
    check("only entries since May", lists:member(<<"pr-octo-beta-7">>, Ids2) andalso not lists:member(<<"pr-octo-alpha-1">>, Ids2)),
    check("account queried by login", [K || {K, _, _} <- maps:get(calls, R2), K =:= account] =:= [account]),

    io:format("# over the cap of 100 repositories: the window splits~n"),
    R3 = run(Ctx, "split", ?BULK, [], []),
    check("exits 0", maps:get(status, R3) =:= 0),
    Ids3 = ids(get([<<"entries">>], maps:get(json, R3))),
    check("all 120 monthly commit rows present",
          lists:sort(Ids3) =:= lists:sort([iolist_to_binary(io_lib:format("commits-octo-bulk-~3..0B-2026-01", [I])) || I <- lists:seq(1, 60)]
                                          ++ [iolist_to_binary(io_lib:format("commits-octo-more-~3..0B-2026-03", [I])) || I <- lists:seq(1, 60)])),
    check("counts per row", get([<<"title">>], entry(<<"commits-octo-more-060-2026-03">>, get([<<"entries">>], maps:get(json, R3)))) =:= <<"2 commits">>),
    check("window was split", count(window, maps:get(calls, R3)) > Windows),
    check("split logged", has(maps:get(output, R3), "over the API caps, splitting")),
    check("latest commits in batches of 50", lists:sort([N || {{latest, N}, _, _} <- maps:get(calls, R3)]) =:= [20, 50, 50]),
    check("120 repositories", get([<<"meta">>, <<"repositories">>], maps:get(json, R3)) =:= 120),

    io:format("# the API rejecting windows over five months: split until accepted~n"),
    R4 = run(Ctx, "rejected", ?DATASET, [{"CATALOG_FAKE_MAX_MONTHS", "5"}], []),
    check("exits 0", maps:get(status, R4) =:= 0),
    check("same entries as the basic run", lists:sort(ids(get([<<"entries">>], maps:get(json, R4)))) =:= lists:sort(?EXPECTED_IDS)),
    check("same restricted count", get([<<"meta">>, <<"restricted">>], maps:get(json, R4)) =:= 10),
    check("more window calls than windows", count(window, maps:get(calls, R4)) > Windows),
    check("rejection logged", has(maps:get(output, R4), "rejected, splitting")),

    io:format("# the API rejecting even one month: the run stops~n"),
    R5 = run(Ctx, "rejected-month", ?DATASET, [{"CATALOG_FAKE_MAX_MONTHS", "0"}], []),
    check("exits 1", maps:get(status, R5) =:= 1),
    check("nothing written", maps:get(json, R5) =:= undefined),
    check("error shown", has(maps:get(output, R5), "must not exceed 1 year")),

    case get(failed) of
        undefined -> io:format("all checks passed (~s)~n", [Tmp]);
        N -> io:format("~B check(s) FAILED (~s)~n", [N, Tmp]), halt(1)
    end.

%% ---- running the generator -----------------------------------------------------

run(#{root := Root, tmp := Tmp, bin := Bin}, Name, Dataset, Env, Args) ->
    Dir = filename:join(Tmp, Name),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    DataFile = filename:join(Dir, "data.terms"),
    ok = file:write_file(DataFile, [io_lib:format("~p.~n", [T]) || T <- Dataset]),
    Log = filename:join(Dir, "calls.log"),
    Out = filename:join(Dir, "contributions"),
    Port = open_port({spawn_executable, os:find_executable("escript")},
                     [{args, [filename:join([Root, "tools", "catalog.escript"]), "--out", Out | Args]},
                      {env, [{"PATH", Bin ++ ":" ++ os:getenv("PATH")},
                             {"CATALOG_FAKE_DATA", DataFile}, {"CATALOG_FAKE_LOG", Log} | Env]},
                      binary, exit_status, stream, use_stdio, stderr_to_stdout]),
    {Status, Output} = collect(Port, <<>>),
    io:format("~s", [Output]),
    Calls = case file:consult(Log) of {ok, C} -> C; _ -> [] end,
    Json = case file:read_file(filename:join(Out, "contributions.json")) of
               {ok, J} -> json:decode(J);
               _ -> undefined
           end,
    #{status => Status, output => Output, calls => Calls, json => Json, out => Out}.

collect(Port, Acc) ->
    receive
        {Port, {data, D}} -> collect(Port, <<Acc/binary, D/binary>>);
        {Port, {exit_status, S}} -> {S, Acc}
    end.

tmp_root() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        D -> D
    end.

%% Windows the generator opens from a month up to the current one: the
%% test must not depend on the day it runs.
windows_since({Y0, M0}) ->
    {{Y, M, _}, _} = calendar:universal_time(),
    Months = (Y - Y0) * 12 + (M - M0) + 1,
    (Months + 11) div 12.

%% ---- the call log ----------------------------------------------------------------

class({account, _, _}) -> account;
class({{window, _, _}, _, _}) -> window;
class(_) -> lookup.

count(Class, Calls) when Class =:= account; Class =:= window ->
    length([C || C <- Calls, class(C) =:= Class]);
count(Kind, Calls) ->
    length([C || C = {{K, _}, _, _} <- Calls, K =:= Kind]).

last_end(Class, Calls) -> lists:max([E || C = {_, _, E} <- Calls, class(C) =:= Class]).
first_start(Class, Calls) -> lists:min([S || C = {_, S, _} <- Calls, class(C) =:= Class]).

%% Largest number of calls in flight at one instant: ends sort before
%% starts at the same millisecond, so touching calls do not count.
max_overlap(Calls) ->
    Events = lists:sort(lists:append([[{S, 1}, {E, -1}] || {_, S, E} <- Calls])),
    {_, Max} = lists:foldl(fun({_, D}, {N, Mx}) -> {N + D, max(Mx, N + D)} end, {0, 0}, Events),
    Max.

%% ---- checks ---------------------------------------------------------------------

check(Name, true) -> io:format("ok - ~s~n", [Name]);
check(Name, false) -> io:format("FAIL - ~s~n", [Name]), put(failed, case get(failed) of undefined -> 1; N -> N + 1 end).

ids(Entries) -> [get([<<"id">>], E) || E <- Entries].

entry(Id, Entries) ->
    case [E || E <- Entries, get([<<"id">>], E) =:= Id] of
        [E] -> E;
        _ -> #{}
    end.

has(Text, Part) -> string:find(Text, Part) =/= nomatch.

get([], V) -> V;
get([K | Ks], M) when is_map(M) -> get(Ks, maps:get(K, M, undefined));
get(_, _) -> undefined.
