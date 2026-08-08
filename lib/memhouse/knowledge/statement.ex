# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Knowledge.Statement do
  @moduledoc """
  Normalization and the readability rule for knowledge statement text.

  The statement is the knowledge atom, so the only thing that makes a row worth
  keeping is that a human can read it later without the observation beside it.
  A blank check does not establish that. A generation that collapses into
  repeated ellipsis, or that pads a few words with zero-width spaces, is a
  non-blank string of the right type and passes every structural check while
  carrying no claim.

  Two functions express the rule so that the extraction cast and the resource
  enforce the same one:

  - `normalize/1` removes zero-width characters and collapses whitespace runs.
    It runs before hashing, so two observations that differ only in invisible
    padding corroborate one row instead of creating two.
  - `prose?/1` measures how much of the text is letters and digits.

  ## What the ratio does and does not catch

  It catches dilution: a collapse into punctuation, ellipsis, or invisible
  padding. It does not catch a repetition of real words ("the the the"), which
  scores like prose. Detecting that needs a different measure, and guessing at
  one here would reject legitimate statements.
  """

  # Zero-width space, non-joiner, joiner, and the byte-order mark. These carry no
  # meaning in a statement, and a model that emits them is padding rather than
  # writing.
  @invisible ~r/[\x{200B}-\x{200D}\x{FEFF}]/u

  @alnum ~r/^[[:alnum:]]$/u

  # Least share of non-space characters that must be letters or digits. Measured
  # prose sits at 0.79 and above, including statements carrying dates, currency,
  # quotation, and em dashes; the observed collapse sits below 0.40.
  @min_alnum_ratio 0.6

  # Non-space characters a statement needs before the ratio is applied. Below it
  # a legitimate fragment such as "R&D — 40%." has too few characters for the
  # ratio to distinguish it from noise.
  @ratio_floor 24

  @doc """
  Removes invisible characters, collapses whitespace runs to one space, and
  trims.

  Returns the normalized string. Text with nothing left normalizes to `""`,
  which the caller must still reject as blank.
  """
  def normalize(text) when is_binary(text) do
    text
    |> String.replace(@invisible, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @doc """
  Says whether text reads as prose rather than filler.

  Normalizes first, so the answer does not depend on the caller having done so.
  Returns `false` for text that normalizes to nothing and for text with no
  letters or digits at all, `true` for anything shorter than the ratio floor,
  and otherwise `true` only when enough of the non-space characters are letters
  or digits.
  """
  def prose?(text) when is_binary(text) do
    characters =
      text
      |> normalize()
      |> String.graphemes()
      |> Enum.reject(&(&1 == " "))

    count = length(characters)
    alnum = Enum.count(characters, &(&1 =~ @alnum))

    cond do
      # Short filler would otherwise pass under the ratio floor, and no real
      # statement is made entirely of punctuation.
      alnum == 0 -> false
      count < @ratio_floor -> true
      true -> alnum / count >= @min_alnum_ratio
    end
  end
end
