defmodule Loupey.HA.Messages do
  @moduledoc """
  Pure functions for parsing and encoding Home Assistant WebSocket messages.

  No side effects, no processes — just data in, data out. Used by `HAConnection`
  to translate between JSON on the wire and Elixir structs.

  ## HA WebSocket Protocol

  All messages are JSON objects with a `type` field. After authentication,
  client messages require an integer `id` for response correlation.

  ### Server → Client message types:
  - `auth_required` — server greeting, prompts for auth
  - `auth_ok` — authentication succeeded
  - `auth_invalid` — authentication failed
  - `result` — response to a command (keyed by `id`)
  - `event` — subscription event (state_changed, etc.)

  ### Client → Server message types:
  - `auth` — send access token
  - `subscribe_events` — subscribe to event types
  - `call_service` — call an HA service
  - `get_states` — fetch all current entity states
  """

  alias Loupey.HA.{EntityState, ServiceCall}

  # -- Parsing (JSON string → Elixir terms) --

  @type parsed_message ::
          :auth_required
          | :auth_ok
          | {:auth_invalid, String.t()}
          | {:result, integer(), boolean(), term()}
          | {:state_changed, integer(), EntityState.t(), EntityState.t() | nil}
          | {:event, integer(), String.t(), map()}
          | {:states, integer(), [EntityState.t()]}
          | {:unknown, map()}

  @doc """
  Parse a raw JSON string from the HA WebSocket into a tagged tuple.
  """
  @spec parse(String.t()) :: parsed_message()
  def parse(json) do
    json
    |> Jason.decode!()
    |> parse_decoded()
  end

  defp parse_decoded(%{"type" => "auth_required"}), do: :auth_required

  defp parse_decoded(%{"type" => "auth_ok"}), do: :auth_ok

  defp parse_decoded(%{"type" => "auth_invalid", "message" => msg}),
    do: {:auth_invalid, msg}

  defp parse_decoded(%{"type" => "auth_invalid"}),
    do: {:auth_invalid, "unknown reason"}

  defp parse_decoded(%{
         "type" => "event",
         "id" => id,
         "event" => %{
           "event_type" => "state_changed",
           "data" => %{
             "entity_id" => entity_id,
             "new_state" => new_state_map
           } = data
         }
       }) do
    new_state = parse_state(entity_id, new_state_map)

    old_state =
      case Map.get(data, "old_state") do
        nil -> nil
        old -> parse_state(entity_id, old)
      end

    {:state_changed, id, new_state, old_state}
  end

  defp parse_decoded(%{"type" => "event", "id" => id, "event" => %{"event_type" => type} = event}),
    do: {:event, id, type, event}

  defp parse_decoded(%{"type" => "result", "id" => id, "success" => success, "result" => result})
       when is_list(result) do
    # Check if this is a get_states response (list of state objects)
    if Enum.all?(result, &is_map(&1) && Map.has_key?(&1, "entity_id")) do
      states = Enum.map(result, fn s -> parse_state(s["entity_id"], s) end)
      {:states, id, states}
    else
      {:result, id, success, result}
    end
  end

  defp parse_decoded(%{"type" => "result", "id" => id, "success" => success} = msg),
    do: {:result, id, success, Map.get(msg, "result")}

  defp parse_decoded(msg), do: {:unknown, msg}

  defp parse_state(_entity_id, nil), do: nil

  defp parse_state(entity_id, state_map) do
    %EntityState{
      entity_id: entity_id,
      state: Map.get(state_map, "state", "unknown"),
      attributes: Map.get(state_map, "attributes", %{}),
      last_changed: Map.get(state_map, "last_changed"),
      last_updated: Map.get(state_map, "last_updated")
    }
  end

  # -- Encoding (Elixir terms → JSON string) --

  @doc """
  Encode an authentication message.
  """
  @spec encode_auth(String.t()) :: String.t()
  def encode_auth(token) do
    Jason.encode!(%{type: "auth", access_token: token})
  end

  @doc """
  Encode a subscribe_events message.
  """
  @spec encode_subscribe(integer(), String.t()) :: String.t()
  def encode_subscribe(id, event_type \\ "state_changed") do
    Jason.encode!(%{id: id, type: "subscribe_events", event_type: event_type})
  end

  @doc """
  Encode a get_states message to fetch all current entity states.
  """
  @spec encode_get_states(integer()) :: String.t()
  def encode_get_states(id) do
    Jason.encode!(%{id: id, type: "get_states"})
  end

  @doc """
  Encode a service call message.
  """
  @spec encode_service_call(integer(), ServiceCall.t()) :: String.t()
  def encode_service_call(id, %ServiceCall{} = call) do
    msg = %{
      id: id,
      type: "call_service",
      domain: call.domain,
      service: call.service
    }

    msg = if call.target, do: Map.put(msg, :target, call.target), else: msg
    msg = if call.service_data != %{}, do: Map.put(msg, :service_data, call.service_data), else: msg

    Jason.encode!(msg)
  end

  # -- State diffing --

  @doc """
  Determine if a state change is meaningful enough to trigger a re-render.

  Returns false for changes that only update `last_updated` without changing
  the actual state value or attributes.
  """
  @spec state_changed?(EntityState.t() | nil, EntityState.t()) :: boolean()
  def state_changed?(nil, _new), do: true

  def state_changed?(%EntityState{} = old, %EntityState{} = new) do
    old.state != new.state or old.attributes != new.attributes
  end
end
