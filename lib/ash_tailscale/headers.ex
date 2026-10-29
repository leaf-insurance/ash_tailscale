defmodule AshTailscale.Headers do
  @moduledoc false

  @fields [
    {"tailscale-user-login", :login, 4096, 1024},
    {"tailscale-user-name", :name, 16_384, 4096},
    {"tailscale-user-profile-pic", :profile_pic, 16_384, 4096},
    {"tailscale-app-capabilities", :capabilities, 65_536, 16_384}
  ]
  @word "=\\?([a-zA-Z0-9-]+)\\?([qQbB])\\?([^?\\s]*)\\?="
  @words Regex.compile!("\\A#{@word}(?:[ \\t]+#{@word})*\\z")
  @single Regex.compile!(@word)

  @spec parse(term()) :: {:ok, map()} | {:error, :invalid_headers}
  def parse(headers) when is_list(headers) do
    with {:ok, headers} <- collect(headers),
         {:ok, attrs} <- decode_fields(headers),
         login when is_binary(login) and login != "" <- attrs.login,
         false <- String.trim(login) == "",
         {:ok, caps} <- capabilities(attrs.capabilities) do
      {:ok,
       %{
         attrs
         | capabilities: caps,
           name: optional(attrs.name),
           profile_pic: optional(attrs.profile_pic)
       }}
    else
      _ -> {:error, :invalid_headers}
    end
  end

  def parse(_), do: {:error, :invalid_headers}

  defp collect(headers) do
    Enum.reduce_while(headers, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_binary(key) and is_binary(value) ->
        key = String.downcase(key)

        cond do
          not Enum.any?(@fields, &(elem(&1, 0) == key)) -> {:cont, {:ok, acc}}
          Map.has_key?(acc, key) -> {:halt, :error}
          true -> {:cont, {:ok, Map.put(acc, key, value)}}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  defp decode_fields(headers) do
    Enum.reduce_while(@fields, {:ok, %{}}, fn {header, field, raw_max, decoded_max}, {:ok, acc} ->
      case decode(Map.get(headers, header), raw_max, decoded_max, field) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp decode(nil, _, _, _), do: {:ok, nil}

  defp decode(raw, raw_max, decoded_max, field) when byte_size(raw) <= raw_max do
    case decode_words(raw) do
      {:ok, decoded} when byte_size(decoded) > decoded_max ->
        :error

      {:ok, decoded} ->
        valid_decoded? =
          if field == :capabilities, do: String.valid?(decoded), else: valid_text?(decoded)

        if valid_text?(String.replace(raw, "\t", " ")) and valid_decoded? do
          {:ok, decoded}
        else
          decoding_failure(field)
        end

      _ ->
        decoding_failure(field)
    end
  end

  defp decode(_, _, _, _), do: :error

  # Display data must not lock out an otherwise valid identity assertion.
  # Raw/decoded byte violations above remain hard failures for every field.
  defp decoding_failure(field) when field in [:name, :profile_pic], do: {:ok, nil}
  defp decoding_failure(_), do: :error

  defp decode_words(raw) do
    # Go encodes the whole value. Encoded-looking substrings in raw JSON or
    # display text are data, not a request to recursively decode that data.
    if String.starts_with?(raw, "=?") do
      if Regex.match?(@words, raw), do: decode_encoded_words(raw), else: :error
    else
      {:ok, raw}
    end
  end

  defp decode_encoded_words(raw) do
    Regex.scan(@single, raw, capture: :all_but_first)
    |> Enum.reduce_while({:ok, []}, fn [charset, encoding, content], {:ok, acc} ->
      case decode_word(String.downcase(charset), String.downcase(encoding), content) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary()}
      _ -> :error
    end
  end

  defp decode_word("utf-8", "q", content), do: decode_q(content, [])
  defp decode_word("utf-8", "b", content), do: Base.decode64(content)
  defp decode_word(_, _, _), do: :error

  defp decode_q(<<>>, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  defp decode_q(<<?_, rest::binary>>, acc), do: decode_q(rest, [" " | acc])

  defp decode_q(<<?=, a, b, rest::binary>>, acc) do
    case Base.decode16(<<a, b>>, case: :mixed) do
      {:ok, byte} -> decode_q(rest, [byte | acc])
      _ -> :error
    end
  end

  defp decode_q(<<c, rest::binary>>, acc) when c in 33..126 and c not in [?=, ??],
    do: decode_q(rest, [<<c>> | acc])

  defp decode_q(_, _), do: :error

  defp valid_text?(value) do
    String.valid?(value) and not Regex.match?(~r/[\x00-\x1F\x7F]/, value)
  end

  defp optional(""), do: nil
  defp optional(value), do: value

  defp capabilities(nil), do: {:ok, %{}}

  defp capabilities(json) do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> :error
    end
  end
end
