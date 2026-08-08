# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.UpdateTest do
  use ExUnit.Case, async: true

  alias MemHouse.Update

  test "accepts only a manifest signed by its configured Ed25519 key" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    manifest =
      Jason.encode!(%{
        "schema" => "memhouse-release-1",
        "version" => "0.3.1",
        "automatic_eligible" => true,
        "assets" => []
      })

    signature = :crypto.sign(:eddsa, :none, manifest, [private_key, :ed25519]) |> Base.encode64()
    config = [public_key: Base.encode64(public_key)]

    assert {:ok, %{"version" => "0.3.1"}} = Update.verify_manifest(manifest, signature, config)

    assert {:error, :invalid_signature} =
             Update.verify_manifest(manifest <> " ", signature, config)
  end

  test "compares stable semantic versions and rejects malformed values" do
    assert Update.newer?("0.3.1", "0.3.0")
    assert Update.newer?("1.0.0", "0.99.99")
    refute Update.newer?("0.3.0", "0.3.0")
    refute Update.newer?("0.3.0-rc.1", "0.3.0")
    refute Update.newer?("not-a-version", "0.3.0")
  end
end
