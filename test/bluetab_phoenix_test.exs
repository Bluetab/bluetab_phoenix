defmodule BluetabPhoenixTest do
  use ExUnit.Case

  test "app layout includes tempo-style navbar components" do
    source = BluetabPhoenix.app_layout_function("Tempo", MyAppWeb)

    assert source =~ "bt_topbar"
    assert source =~ "logo-bluetab.svg"
    assert source =~ "bt_navbar_user_menu_prefs"
    assert source =~ "bt_navbar_user_menu_locale_toggle"
    assert source =~ "bt_navbar_user_menu_theme_toggle"
    refute source =~ ~s|<.bt_navbar_theme_toggle label={gettext("Toggle theme")} />\n                <.bt_navbar_user_menu|
  end

  test "layout helpers include locale and initials functions" do
    helpers = BluetabPhoenix.layout_helpers(MyAppWeb)

    assert helpers =~ "defp user_initials"
    assert helpers =~ "defp navbar_locales"
    assert helpers =~ "MyAppWeb.Plugs.SetLocale"
  end

  test "locale plug source configures gettext and cookie" do
    source = BluetabPhoenix.locale_plug_source(MyAppWeb, :my_app)

    assert source =~ "defmodule MyAppWeb.Plugs.SetLocale"
    assert source =~ "_my_app_locale"
    assert source =~ "MyAppWeb.Gettext"
  end
end
