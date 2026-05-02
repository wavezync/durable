defmodule Mix.Tasks.Durable.GenUpgradeTest do
  use ExUnit.Case, async: false

  alias Durable.Migration
  alias Mix.Tasks.Durable.Gen.Upgrade, as: GenUpgradeTask

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  @tag :tmp_dir
  test "generates a Durable upgrade migration for the current version", %{tmp_dir: tmp_dir} do
    target = Migration.current_version()
    previous = Migration.previous_version(target)

    assert [file] =
             GenUpgradeTask.run([
               "-r",
               "Durable.TestRepo",
               "--migrations-path",
               tmp_dir
             ])

    assert Path.basename(file) =~ "_upgrade_durable_to_v#{target}.exs"

    content = File.read!(file)
    assert content =~ "defmodule Durable.TestRepo.Migrations.UpgradeDurableToV#{target}"
    assert content =~ "Durable.Migration.up(to: #{target}, prefix: \"durable\")"
    assert content =~ "Durable.Migration.down(to: #{previous}, prefix: \"durable\")"
  end

  @tag :tmp_dir
  test "supports custom prefix and target version", %{tmp_dir: tmp_dir} do
    target = hd(Migration.all_versions())

    assert [file] =
             GenUpgradeTask.run([
               "-r",
               "Durable.TestRepo",
               "--migrations-path",
               tmp_dir,
               "--prefix",
               "private",
               "--to",
               Integer.to_string(target)
             ])

    content = File.read!(file)
    assert content =~ "Durable.Migration.up(to: #{target}, prefix: \"private\")"
    assert content =~ "Durable.Migration.down(to: 0, prefix: \"private\")"
  end

  @tag :tmp_dir
  test "refuses to generate a duplicate upgrade migration", %{tmp_dir: tmp_dir} do
    target = Migration.current_version()
    base_name = "upgrade_durable_to_v#{target}"
    File.write!(Path.join(tmp_dir, "20250101000000_#{base_name}.exs"), "")

    assert_raise Mix.Error, ~r/already a migration file/, fn ->
      GenUpgradeTask.run([
        "-r",
        "Durable.TestRepo",
        "--migrations-path",
        tmp_dir
      ])
    end
  end

  @tag :tmp_dir
  test "raises for unknown target versions", %{tmp_dir: tmp_dir} do
    assert_raise Mix.Error, ~r/Unknown Durable migration version/, fn ->
      GenUpgradeTask.run([
        "-r",
        "Durable.TestRepo",
        "--migrations-path",
        tmp_dir,
        "--to",
        "99999999999999"
      ])
    end
  end

  @tag :tmp_dir
  test "raises for an invalid repo", %{tmp_dir: tmp_dir} do
    assert_raise Mix.Error, ~r/Could not load Missing.Repo/, fn ->
      GenUpgradeTask.run([
        "-r",
        "Missing.Repo",
        "--migrations-path",
        tmp_dir
      ])
    end
  end
end
