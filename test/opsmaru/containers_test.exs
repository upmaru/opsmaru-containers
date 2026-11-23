defmodule Opsmaru.ContainersTest do
  use ExUnit.Case, async: true

  test "the dependency has no application callback" do
    {:ok, _} = Application.ensure_all_started(:opsmaru_containers)

    assert Application.spec(:opsmaru_containers, :mod) == []
  end
end
