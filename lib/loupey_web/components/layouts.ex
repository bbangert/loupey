defmodule LoupeyWeb.Layouts do
  @moduledoc """
  Layout components for the web interface.
  """
  use LoupeyWeb, :html

  import LoupeyWeb.CoreComponents

  embed_templates "layouts/*"
end
