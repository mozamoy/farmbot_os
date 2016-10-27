defmodule Auth do
  require GenServer
  require Logger

  @moduledoc """
    Gets a token and device information
  """

  def get_public_key(server) do
    resp = HTTPotion.get("#{server}/api/public_key")
    case resp do
      %HTTPotion.ErrorResponse{message: "enetunreach"}    -> get_public_key(server)
      %HTTPotion.ErrorResponse{message: "ehostunreach"}   -> get_public_key(server)
      %HTTPotion.ErrorResponse{message: "nxdomain"}       -> get_public_key(server)
      %HTTPotion.ErrorResponse{message: message}          -> {:error, message}
      %HTTPotion.Response{body: body,
                          headers: _headers,
                          status_code: 200}               -> RSA.decode_key(body)
    end
  end

  def encrypt(email, pass, server) do
    # Json to encrypt.
    json = Poison.encode!(%{"email": email,"password": pass,
        "id": Nerves.Lib.UUID.generate,"version": 1})
    secret = String.Chars.to_string(RSA.encrypt(json, {:public, get_public_key(server)}))
    save_encrypted(secret, server)
    secret
  end

  @doc """
    Saves the secret and the server to disk.
  """
  def save_encrypted(secret, server) do
    SafeStorage.write(__MODULE__, :erlang.term_to_binary(%{secret: secret, server: server}))
  end

  @doc """
    Loads the secret and server from disk
    if there is no file returns nil
  """
  def load_encrypted do
    case SafeStorage.read(__MODULE__) do
      {:ok, t} -> get_token(Map.get(t, :secret), Map.get(t, :server))
      _ -> nil
    end

  end

  # Gets a token from the API with given secret and server
  def get_token(secret, server) do
    if(!Wifi.connected?) do
      Process.sleep(80)
      get_token(secret, server)
    end
    payload = Poison.encode!(%{user: %{credentials: :base64.encode_to_string(secret) |> String.Chars.to_string }} )
    case HTTPotion.post "#{server}/api/tokens", [body: payload, headers: ["Content-Type": "application/json"]] do
      %HTTPotion.ErrorResponse{message: "enetunreach"} -> get_token(secret, server)
      %HTTPotion.ErrorResponse{message: "nxdomain"} -> get_token(secret, server)
      %HTTPotion.ErrorResponse{message: reason} -> {:error, reason}
      %HTTPotion.Response{body: _, headers: _, status_code: 422} -> Fw.factory_reset
      %HTTPotion.Response{body: _, headers: _, status_code: 401} -> Fw.factory_reset
      %HTTPotion.Response{body: body, headers: _headers, status_code: 200} ->
          Map.get(Poison.decode!(body), "token")
    end
  end

  def get_token do
    GenServer.call(__MODULE__, {:get_token})
  end

  # Infinite recursion until we have a token.
  # Not concerned about performance yet because the bot can't do anything anything.
  def fetch_token do
    case Auth.get_token do
      nil -> fetch_token
      {:error, reason} -> IO.puts("something weird happened")
                          IO.inspect(reason)
                          {:error, reason}
      token -> token
    end
  end

  # Genserver stuff
  def init(_args) do
    {:ok, load_encrypted}
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__ )
  end

  # Am i even using this?
  def login(email,pass,server) when is_bitstring(email)
        and is_bitstring(pass)
        and is_bitstring(server) do
    case Wifi.connected? do
      true ->
        GenServer.call(__MODULE__, {:login, email,pass,server}, 15000 )
      _ ->
        Process.sleep(10001)
        login(email,pass,server) # Probably process heavy here but im lazy
    end
  end

  def handle_call({:login, email,pass,server}, _from, _old_token) do
    secret = encrypt(email,pass,server)
    token = get_token(secret, server)
    {:reply,token,token}
  end

  def handle_call({:get_token}, _from, token) do
    {:reply, token, token}
  end

  def terminate(reason, something) do
    Logger.debug("AUTH DIED: #{inspect {reason, something}}")
    # Fw.factory_reset
  end
end
