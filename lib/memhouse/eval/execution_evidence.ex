# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.ExecutionEvidence do
  @moduledoc """
  Validates that execute-mode evidence matches a variant's component controls.

  A completed tool outcome is evidence that the tool ran. It must agree with the
  corresponding component control in both directions: enabled tools must complete,
  and disabled tools must not complete.
  """

  @doc """
  Validates completion evidence for one recall tool.

  Returns `:ok` when the component control and completed outcome agree. Raises
  `ArgumentError` when an enabled component has no completed outcome or a disabled
  component has one.
  """
  def assert_recall_tool!(recalls, variant, components, component, tool) do
    completed? =
      Enum.any?(recalls, fn recall ->
        Enum.any?(recall["outcomes"] || [], fn outcome ->
          outcome["tool"] == tool and outcome["status"] == "completed"
        end)
      end)

    case {components[component], completed?} do
      {true, false} ->
        raise ArgumentError,
              "execute variant #{inspect(variant["id"])} declared #{component} but completed no #{tool} tool call"

      {false, true} ->
        raise ArgumentError,
              "execute variant #{inspect(variant["id"])} disabled #{component} but completed a #{tool} tool call"

      {_enabled, _completed} ->
        :ok
    end
  end
end
