defmodule SymphonyElixirWeb.Navigation do
  @moduledoc false

  alias SymphonyElixir.Identity.Authorization

  @spec items(map(), String.t()) :: [map()]
  def items(principal, locale), do: Authorization.authorized_navigation(principal, locale)
end
