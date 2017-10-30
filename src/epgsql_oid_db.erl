%%% @author Sergey Prokhorov <me@seriyps.ru>
%%% @doc
%%% Holds Oid <-> Type mappings (forward and reverse).
%%% See https://www.postgresql.org/docs/current/static/catalog-pg-type.html
%%% @end

-module(epgsql_oid_db).

-export([build_query/1, parse_rows/1, join_codecs_oids/2]).
-export([from_list/1, to_list/1, update/2,
         find_by_oid/2, find_by_name/3, oid_by_name/3,
         type_to_codec_entry/1, type_to_oid_info/1, type_to_element_oid/1]).
-export_type([oid/0, oid_info/0, oid_entry/0, type_info/0, db/0]).

-record(type,
        {oid :: oid(),
         name :: epgsql:type_name(),
         is_array :: boolean(),
         array_element_oid :: oid(),
         codec :: module(),
         codec_state :: any()}).
-record(oid_db,
        {by_oid :: dict:dict(oid(), #type{}),
         by_name :: dict:dict(epgsql:type_name(), #type{})}).

-type oid() :: non_neg_integer().
-type oid_entry() :: {epgsql:type_name(), Oid :: oid(), ArrayOid :: oid()}.
-type oid_info() :: {Oid :: oid(), epgsql:type_name(), IsArray :: boolean()}.
-opaque db() :: #oid_db{}.
-opaque type_info() :: #type{}.

-define(DICT, dict).
-define(RECORD_OID, 2249).


%%
%% pg_type Data preparation
%%

%% @doc build query to fetch OID<->type_name information from PG server
-spec build_query([epgsql:type_name() | binary()]) -> iolist().
build_query(TypeNames) ->
    %% TODO: lists:join/2, ERL 19+
    %% XXX: we don't escape type names!
    ToBin = fun(B) when is_binary(B) -> B;
               (A) when is_atom(A) -> atom_to_binary(A, utf8)
            end,
    Types = join(",",
                 [["'", ToBin(TypeName) | "'"]
                  || TypeName <- TypeNames]),
    [<<"SELECT typname, oid::int4, typarray::int4 "
       "FROM pg_type "
       "WHERE typname IN (">>, Types, <<") ORDER BY typname">>].

%% Parse result of `squery(build_query(...))'
-spec parse_rows(ordsets:ordset({binary(), binary(), binary()})) ->
                        ordsets:ordset(oid_entry()).
parse_rows(Rows) ->
    [{binary_to_existing_atom(TypeName, utf8),
      binary_to_integer(Oid),
      binary_to_integer(ArrayOid)}
     || {TypeName, Oid, ArrayOid} <- Rows].

%% Build list of #type{}'s by merging oid and codec lists by type name.
-spec join_codecs_oids(ordsets:ordset(oid_entry()),
                       ordsets:ordset(epgsql_codec:codec_entry())) -> [#type{}].
join_codecs_oids(Oids, Codecs) ->
    do_join(lists:sort(Oids), lists:sort(Codecs)).

do_join([{TypeName, Oid, ArrayOid} | Oids],
        [{TypeName, CallbackMod, CallbackState} | Codecs]) ->
    [#type{oid = Oid, name = TypeName, is_array = false,
           codec = CallbackMod, codec_state = CallbackState},
     #type{oid = ArrayOid, name = TypeName, is_array = true,
           codec = CallbackMod, codec_state = CallbackState,
           array_element_oid = Oid}
     | do_join(Oids, Codecs)];
do_join([OidEntry | _Oids] = Oids, [CodecEntry | Codecs])
  when element(1, OidEntry) > element(1, CodecEntry) ->
    %% This type isn't supported by PG server. That's ok, but not vice-versa.
    do_join(Oids, Codecs);
do_join([], _) ->
    %% Codecs list may be not empty. See prev clause.
    [].


%%
%% Storage API
%%

-spec from_list([type_info()]) -> db().
from_list(Types) ->
    #oid_db{by_oid = ?DICT:from_list(
                       [{Oid, Type} || #type{oid = Oid} = Type <- Types]),
            by_name = ?DICT:from_list(
                        [{{Name, IsArray}, Oid}
                         || #type{name = Name, is_array = IsArray, oid = Oid}
                                <- Types])}.

to_list(#oid_db{by_oid = Dict}) ->
    [Type || {_Oid, Type} <- ?DICT:to_list(Dict)].

-spec update([type_info()], db()) -> db().
update(Types, #oid_db{by_oid = OldByOid, by_name = OldByName} = Store) ->
    #oid_db{by_oid = NewByOid, by_name = NewByName} = from_list(Types),
    ByOid = ?DICT:merge(fun(_, _, V2) -> V2 end, OldByOid, NewByOid),
    ByName = ?DICT:merge(fun(_, _, V2) -> V2 end, OldByName, NewByName),
    Store#oid_db{by_oid = ByOid,
                 by_name = ByName}.

-spec find_by_oid(oid(), db()) -> type_info() | undefined.
%% find_by_oid(?RECORD_OID, _) ->
%%     '$record';
find_by_oid(Oid, #oid_db{by_oid = Dict}) ->
    case ?DICT:find(Oid, Dict) of
        {ok, Type} -> Type;
        error -> undefined
    end.

-spec find_by_name(epgsql:type_name(), boolean(), db()) -> type_info().
find_by_name(Name, IsArray, #oid_db{by_oid = ByOid} = Db) ->
    Oid = oid_by_name(Name, IsArray, Db),
    ?DICT:fetch(Oid, ByOid).                  % or maybe find_by_oid(Oid, Store)

-spec oid_by_name(epgsql:type_name(), boolean(), db()) -> oid().
oid_by_name(Name, IsArray, #oid_db{by_name = ByName}) ->
    ?DICT:fetch({Name, IsArray}, ByName).

-spec type_to_codec_entry(type_info()) -> epgsql_codec:codec_entry().
type_to_codec_entry(#type{name = Name, codec = Codec, codec_state = State}) ->
    {Name, Codec, State}.

-spec type_to_oid_info(type_info()) -> oid_info().
type_to_oid_info(#type{name = Name, is_array = IsArray, oid = Oid}) ->
    {Oid, Name, IsArray}.

-spec type_to_element_oid(type_info()) -> oid() | undefined.
type_to_element_oid(#type{array_element_oid = ElementOid}) ->
    ElementOid.

%% Internal

join(_Sep, []) -> [];
join(Sep, [H | T]) -> [H | join_prepend(Sep, T)].

join_prepend(_Sep, []) -> [];
join_prepend(Sep, [H | T]) -> [Sep, H | join_prepend(Sep, T)].
