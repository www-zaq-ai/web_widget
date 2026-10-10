defmodule WebWidget.Integration.DiagnosticsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias WebWidget.Integration.Diagnostics

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    WebWidget.TestInfrastructure.setup(pubsub_server: WebWidget.PubSub)

    on_exit(fn ->
      Logger.configure(level: previous_level)
    end)

    :ok
  end

  test "summary mode shows response shape and disposition without private values" do
    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      response_diagnostics: :summary
    )

    response = %{
      type: :message_step,
      request_id: "private-request-id",
      payload: %{
        kind: :activity,
        state: :running,
        label: "private-label",
        body: "private-body",
        identity_token: "private-token",
        tool_calls: [%{arguments: "private-arguments", result: "private-result"}],
        metadata: %{trace: ["private-trace"]}
      }
    }

    log = capture_log([level: :info], fn -> Diagnostics.log(:applied, response) end)
    assert log =~ "[web_widget.response]"
    assert log =~ "outcome: :applied"
    assert log =~ "kind: :activity"
    assert log =~ "tool_call_count: 1"
    assert log =~ "metadata_fields: [:trace]"
    refute log =~ "private-"
    refute log =~ "identity_token"

    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      response_diagnostics: false
    )

    assert capture_log(fn -> Diagnostics.log(:applied, response) end) == ""
  end

  test "enabled diagnostics include the complete received payload and unknown nested fields" do
    WebWidget.TestInfrastructure.replace(
      pubsub_server: WebWidget.PubSub,
      response_diagnostics: true
    )

    body = String.duplicate("x", 5_000) <> "END-OF-BODY"

    response = %{
      type: :message_step,
      request_id: "request-123",
      payload: %{
        label: "Using sleep_action",
        body: body,
        tool_calls: Enum.map(1..60, &%{id: &1, arguments: %{duration_ms: 5}, result: "ok"}),
        future_field: %{nested: "preserved"}
      }
    }

    log =
      capture_log([level: :info, truncate: :infinity], fn ->
        Diagnostics.log(:applied, response)
      end)

    assert log =~ "outcome: :applied"
    assert log =~ "request-123"
    assert log =~ body
    assert log =~ "Using sleep_action"
    assert log =~ "id: 60"
    assert log =~ "duration_ms: 5"
    assert log =~ ~s(result: "ok")
    assert log =~ ~s(future_field: %{nested: "preserved"})
  end

  test "history diagnostics identify private field presence without dumping values" do
    summary =
      Diagnostics.summary(%{
        type: :conversation_history,
        payload: %{
          messages: [%{content: "private", metadata: %{tool_calls: ["private"]}, trace: []}]
        }
      })

    assert summary.history_count == 1
    assert summary.history_fields == [:content, :metadata, :trace]
    refute inspect(summary) =~ "private"
    assert Diagnostics.summary(%{payload: %{kind: "private"}}).kind == :unknown
    assert Diagnostics.summary(nil).payload_fields == []
  end
end
