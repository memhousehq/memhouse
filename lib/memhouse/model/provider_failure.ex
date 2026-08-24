# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.ProviderFailure do
  @moduledoc """
  Content-free failure taxonomy shared by provider admission and extraction.

  The circuit asks whether a failure represents provider availability;
  extraction asks whether the same failure needs operator repair. Keeping the
  closed HTTP statuses, ReqLLM validation classes, and structured-response
  atoms here prevents those two decisions from drifting while leaving terminal
  schema exhaustion and open-circuit retry behavior to the pipeline.
  """

  @configuration_statuses [400, 401, 403, 404, 405, 422]
  @structured_response_errors [
    :provider_output_truncated,
    :provider_content_filtered,
    :missing_structured_object
  ]

  @doc """
  Returns whether `error` is a transient provider-availability failure.

  Credential/configuration HTTP statuses, ReqLLM invalid/validation classes,
  and known structured-response failures return `false`; all other errors
  return `true`. The result is a classification only and contains no provider
  message or model content.
  """
  def transient?(%ReqLLM.Error.API.Request{status: status})
      when status in @configuration_statuses,
      do: false

  def transient?(%MemHouse.Operations.ExtractionBudget.Exceeded{}), do: false

  def transient?(%{class: class}) when class in [:invalid, :validation], do: false
  def transient?(reason) when reason in @structured_response_errors, do: false
  def transient?(_error), do: true

  @doc """
  Returns a repairable extraction class for known permanent provider failures.

  Returns `{:repairable, reason_class}` for configuration and structured
  response errors, or `:transient` when the caller should retain ordinary
  provider retry semantics. Reason classes are fixed, content-free strings.
  """
  def extraction_disposition(%ReqLLM.Error.API.Request{status: status})
      when status in @configuration_statuses,
      do: {:repairable, "provider_configuration"}

  def extraction_disposition(%{class: class}) when class in [:invalid, :validation],
    do: {:repairable, "configuration"}

  def extraction_disposition(reason) when reason in @structured_response_errors,
    do: {:repairable, Atom.to_string(reason)}

  def extraction_disposition(_error), do: :transient
end
