defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @default_html_lang "en"

  @spec html_lang(map()) :: String.t()
  def html_lang(source) do
    locale =
      source
      |> locale_candidates()
      |> Enum.find_value(&normalize_html_lang/1)

    locale || @default_html_lang
  end

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:dashboard_css_url, SymphonyElixirWeb.StaticAssets.dashboard_css_url())
      |> assign(:favicon_url, SymphonyElixirWeb.StaticAssets.favicon_url())
      |> assign(:html_lang, html_lang(assigns))

    ~H"""
    <!DOCTYPE html>
    <html lang={@html_lang}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <link rel="icon" type="image/png" sizes="128x128" href={@favicon_url} />
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href={@dashboard_css_url} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end

  defp locale_candidates(%Plug.Conn{} = conn) do
    [
      Map.get(conn.path_params, "locale"),
      Map.get(conn.params, "locale"),
      locale_from_path(conn.request_path),
      conn
      |> Plug.Conn.get_req_header("accept-language")
      |> List.first()
    ]
  end

  defp locale_candidates(%{} = source) do
    [
      locale_from_path(Map.get(source, :request_path)),
      locale_from_path(Map.get(source, "request_path")),
      locale_from_path(Map.get(source, :return_to)),
      locale_from_path(Map.get(source, "return_to")),
      locale_candidates(Map.get(source, :params)),
      locale_candidates(Map.get(source, "params")),
      locale_candidates(Map.get(source, :conn)),
      locale_candidates(Map.get(source, "conn")),
      Map.get(source, :locale),
      Map.get(source, "locale")
    ]
    |> List.flatten()
  end

  defp locale_candidates(_source), do: []

  defp locale_from_path(path) when is_binary(path) do
    case Regex.run(~r{\A/(en|en[-_]US|zh[-_]CN)(?:/|\z)}i, path) do
      [_match, locale] -> locale
      _no_locale -> nil
    end
  end

  defp locale_from_path(_path), do: nil

  defp normalize_html_lang(locale) when is_binary(locale) do
    parts =
      locale
      |> String.split(",", parts: 2)
      |> List.first()
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()
      |> String.replace("_", "-")
      |> String.split("-", trim: true)

    case parts do
      ["en"] -> "en"
      ["en", region] -> if String.downcase(region) == "us", do: "en-US"
      ["zh", region] -> if String.downcase(region) == "cn", do: "zh-CN"
      _unsupported -> nil
    end
  end

  defp normalize_html_lang(_locale), do: nil
end
