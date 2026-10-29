defmodule AshTailscale.Assertion do
  @moduledoc false
  # Server-side adapter input, never request parameters. Not a signed credential.
  @enforce_keys [:headers]
  defstruct [:headers]
end
