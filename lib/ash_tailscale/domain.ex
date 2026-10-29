defmodule AshTailscale.Domain do
  @moduledoc "The library-owned domain for transient request actors."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshTailscale.User
  end
end
