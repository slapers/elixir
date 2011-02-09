% Holds all methods required to bootstrap the object model.
% These methods are overwritten by their Elixir version later in Object::Methods.
-module(elixir_object_methods).
-export([mixin/2, proto/2, new/2, name/1, parent/1, mixins/1, protos/1, data/1,
  get_ivar/2, set_ivar/3, ancestors/1, abstract_parent/1, abstract_data/1,
  get_visibility/1, set_visibility/2, alias_local/5, function_catch/1,
  abstract_methods/1, abstract_public_methods/1, abstract_protected_methods/1,
  public_proto_methods/1]).
-include("elixir.hrl").

% EXTERNAL API

% TODO Disable .new call on native types
new(#elixir_object{name=Name, protos=Protos} = Self, Args) ->
  Parent = case Name of
    [] -> Self;
    _  -> Name
  end,
  Object = #elixir_object{name=[], parent=Parent, mixins=Protos, protos=[], data=[]},
  Data = elixir_dispatch:dispatch(true, Object, constructor, Args),
  Dict = assert_dict_with_atoms(Data),
  Object#elixir_object{data=Dict}.

mixin(Self, Value) when is_list(Value) -> [mixin(Self, Item) || Item <- Value];
mixin(Self, Value) -> prepend_as(Self, mixins, Value).
proto(Self, Value) when is_list(Value) -> [proto(Self, Item) || Item <- Value];
proto(Self, Value) -> prepend_as(Self, protos, Value).

% Reflections

name(Self)      -> object_name(Self).
parent(Self)    -> object_parent(Self).
protos(Self)    -> apply_chain(object_protos(Self), traverse_chain(r_ancestors(Self), [])).
data(Self)      -> object_data(Self).
ancestors(Self) -> lists:reverse(r_ancestors(Self)).

% Mixins reflection. If we are creating an object (i.e. Data is an atom),
% we hardcode "Module::Methods" to the object mixins so we can define methods
% inside the object body.
mixins(#elixir_object{data=Data} = Self) when is_atom(Data) ->
  apply_chain(object_mixins(Self), ['Module::Methods'|traverse_chain(r_ancestors(Self), [])]);
mixins(Self) ->
  apply_chain(object_mixins(Self), traverse_chain(r_ancestors(Self), [])).

% Methods available to all objects

function_catch(Function) ->
  catch Function().

%% PROTECTED API

set_visibility(#elixir_object{name=Name, data=Data}, Visibility) when is_atom(Data) ->
  MethodTable = ?ELIXIR_ATOM_CONCAT([mex_, Name]),
  ets:insert(MethodTable, { visibility, Visibility });

set_visibility(Self, Visibility) ->
  elixir_errors:raise(badarg, "cannot change visibility of defined object").

get_visibility(#elixir_object{name=Name, data=Data}) when is_atom(Data) ->
  MethodTable = ?ELIXIR_ATOM_CONCAT([mex_, Name]),
  ets:lookup_element(MethodTable, visibility, 2);

get_visibility(Self) ->
  [].

get_ivar(Self, Name) when not is_atom(Name) ->
  elixir_errors:raise(badarg, "instance variable name needs to be an atom, got ~ts", [inspect(Name)]);

get_ivar(#elixir_object{data=Data}, Name) when is_atom(Data) ->
  Dict = ets:lookup_element(Data, data, 2),
  get_ivar_dict(Name, Dict);

get_ivar(#elixir_object{data=Dict}, Name) ->
  get_ivar_dict(Name, Dict);

get_ivar(Self, Name) -> % Native types do not have instance variables.
  [].

set_ivar(Self, Name, Value) when not is_atom(Name) ->
  elixir_errors:raise(badarg, "instance variable name needs to be an atom, got ~ts", [inspect(Name)]);

set_ivar(#elixir_object{data=Data} = Self, Name, Value) when is_atom(Data) ->
  Dict = ets:lookup_element(Data, data, 2),
  Object = set_ivar_dict(Self, Name, Value, Dict),
  ets:insert(Data, { data, Object#elixir_object.data }),
  Object;

set_ivar(#elixir_object{data=Dict} = Self, Name, Value) ->
  set_ivar_dict(Self, Name, Value, Dict);

% TODO Cannot set ivar on native types.
set_ivar(Self, Name, Value) ->
  Self.

alias_local(#elixir_object{name=Name, data=Data} = Self, Filename, Old, New, ElixirArity) when is_atom(Data) ->
  Arity = ElixirArity + 1,
  MethodTable = ?ELIXIR_ATOM_CONCAT([mex_, Name]),
  case ets:lookup(MethodTable, { Old, Arity }) of
    [{{Old, Arity}, Line, Clauses}] ->
      elixir_object:store_wrapped_method(Name, Filename, {function, Line, New, Arity, Clauses});
    [] ->
      elixir_errors:raise(nomethod, "No local method ~s/~w in ~s", [Old, Arity, Name])
  end;

alias_local(_, _, _, _, _) ->
  elixir_errors:raise(badarg, "cannot alias local method outside object definition scope").

public_proto_methods(Self) ->
  calculate_methods(fun abstract_public_methods/1, protos(Self), []).

% HELPERS

calculate_methods(Fun, [], Acc) ->
  Acc;

calculate_methods(Fun, [H|T], Acc) ->
  calculate_methods(Fun, T, umerge(Acc, Fun(H))).

get_ivar_dict(Name, Data) ->
  case dict:find(Name, Data) of
    { ok, Value } -> Value;
    error -> []
  end.

set_ivar_dict(Self, Name, Value, Dict) ->
  Self#elixir_object{data=dict:store(Name, Value, Dict)}.

assert_dict_with_atoms(#elixir_object{parent='Dict'} = Data) ->
  Dict = get_ivar(Data, dict),
  case lists:all(fun is_atom/1, dict:fetch_keys(Dict)) of
    true  -> Dict;
    false ->
      elixir_errors:raise(badarg, "constructor needs to return a Dict with all keys as symbols, got ~ts", [inspect(Data)])
  end;

assert_dict_with_atoms(Data) ->
  elixir_errors:raise(badarg, "constructor needs to return a Dict, got ~ts", [inspect(Data)]).

inspect(Object) ->
  get_ivar(elixir_dispatch:dispatch(false, Object, inspect, []), bin).

% TODO Only allow modules to be proto/mixed in.
% TODO Handle native types
% TODO Allow to call mixin outside object definition
prepend_as(#elixir_object{} = Self, Kind, Value) ->
  Name  = Self#elixir_object.name,
  Table = Self#elixir_object.data,
  Data  = ets:lookup_element(Table, Kind, 2),
  List  = Value#elixir_object.protos,

  % If we are adding prototypes and the current name is
  % in the list of protos, this means we are adding a
  % proto to a module and we need to ensure all added modules
  % will come after the module name in the proto list.
  case lists:member(Name, Data) of
    true ->
      { Before, After } = lists:splitwith(fun(X) -> X /= Name end, Data),
      Final = umerge(List, lists:delete(Name, After)),
      Updated = umerge(Before, umerge([Name], Final));
    _ ->
      Updated = umerge(List, Data)
  end,

  ets:insert(Table, {Kind, Updated}).

% Merge two lists taking into account uniqueness. Opposite to
% lists:umerge2, does not require lists to be sorted.

umerge(List, Data) ->
  umerge2(lists:reverse(List), Data).

umerge2([], Data) ->
  Data;

umerge2([H|T], Data) ->
  case lists:member(H, Data) of
    true  -> New = Data;
    false -> New = [H|Data]
  end,
  umerge2(T, New).

% Returns the ancestors chain considering only parents, but in reverse order.

r_ancestors(Object) ->
  r_ancestors(object_parent(Object), []).

r_ancestors([], Acc) ->
  Acc;

r_ancestors(Name, Acc) ->
  r_ancestors(abstract_parent(Name), [Name|Acc]).

% Methods that get values from objects. Argument can either be an
% #elixir_object or an erlang native type.

object_name(#elixir_object{name=Name}) ->
  Name;

object_name(Native) ->
  []. % Native types are instances and has no name.

object_parent(#elixir_object{parent=Parent}) ->
  Parent;

object_parent(Native) when is_integer(Native) ->
  'Integer';

object_parent(Native) when is_float(Native) ->
  'Float';

object_parent(Native) when is_atom(Native) ->
  'Atom';

object_parent(Native) when is_list(Native) ->
  'List';

object_parent(Native) when is_binary(Native) ->
  'Binary';

object_parent(Native) when is_tuple(Native) ->
  'Tuple'.

object_mixins(#elixir_object{data=Data}) when is_atom(Data) ->
  ets:lookup_element(Data, mixins, 2);

object_mixins(#elixir_object{mixins=Mixins}) ->
  Mixins;

object_mixins(Native) ->
  []. % Native types has all mixins from parents.

object_protos(#elixir_object{data=Data}) when is_atom(Data) ->
  ets:lookup_element(Data, protos, 2);

object_protos(#elixir_object{protos=Protos}) ->
  Protos;

object_protos(Native) ->
  []. % Native types has no protos.

object_data(#elixir_object{data=Data}) when is_atom(Data) ->
  ets:lookup_element(Data, data, 2);

object_data(#elixir_object{data=Data}) ->
  Data;

object_data(Native) ->
  dict:new(). % Native types has no protos.

% Method that get values from parents. Argument can either be an atom
% or an #elixir_object.

abstract_parent(#elixir_object{parent=Parent}) ->
  Parent;

abstract_parent(Name) ->
  case proplists:get_value(parent, elixir_constants:lookup(Name, attributes)) of
    []   -> [];
    Else -> hd(Else)
  end.

abstract_mixins(#elixir_object{mixins=Mixins}) ->
  Mixins;

abstract_mixins(Name) ->
  proplists:get_value(mixins, elixir_constants:lookup(Name, attributes)).

abstract_protos(#elixir_object{protos=Protos}) ->
  Protos;

abstract_protos(Name) ->
  proplists:get_value(protos, elixir_constants:lookup(Name, attributes)).

abstract_data(#elixir_object{data=Data}) ->
  Data;

abstract_data(Name) ->
  hd(proplists:get_value(data, elixir_constants:lookup(Name, attributes))).

% Get methods from abstract stuff.

abstract_methods(#elixir_object{}) ->
  [];

abstract_methods(Name) ->
  Converter = fun({Name, Arity}) -> {Name, Arity - 1} end,
  lists:map(Converter, elixir_constants:lookup(Name, functions) -- [{module_info,0},{module_info,1}]).

abstract_public_methods(#elixir_object{}) ->
  [];

abstract_public_methods(Name) ->
  abstract_methods(Name) -- abstract_protected_methods(Name).

abstract_protected_methods(#elixir_object{}) ->
  [];

abstract_protected_methods(Name) ->
  proplists:get_value(protected, elixir_constants:lookup(Name, attributes)).

% Methods that traverses the ancestors chain and append.

traverse_chain([], Acc) ->
  Acc;

traverse_chain([H|T], Acc) ->
  traverse_chain(T, apply_chain(abstract_protos(H), Acc)).

apply_chain(List, Acc) ->
  umerge(List, Acc).