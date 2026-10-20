defmodule WebWidgetWeb.Localization do
  @moduledoc false
  use Gettext, backend: WebWidgetWeb.Gettext

  def strings(locale) do
    Gettext.with_locale(WebWidgetWeb.Gettext, locale, fn ->
      %{
        "Ask a question…" => dgettext("widget", "Ask a question…"),
        "Ask a follow-up…" => dgettext("widget", "Ask a follow-up…"),
        "Today" => dgettext("widget", "Today"),
        "Yesterday" => dgettext("widget", "Yesterday"),
        "Message" => dgettext("widget", "Message"),
        "Send message" => dgettext("widget", "Send message"),
        "Connection lost. Reconnecting…" => dgettext("widget", "Connection lost. Reconnecting…"),
        "Reconnecting to recover the response…" =>
          dgettext("widget", "Reconnecting to recover the response…"),
        "Working…" => dgettext("widget", "Working…"),
        "Sending…" => dgettext("widget", "Sending…"),
        "Submission outcome is unknown. Restore the conversation before sending again." =>
          dgettext(
            "widget",
            "Submission outcome is unknown. Restore the conversation before sending again."
          ),
        "Send" => dgettext("widget", "Send"),
        "Open conversation" => dgettext("widget", "Open conversation"),
        "Conversations" => dgettext("widget", "Conversations"),
        "New chat" => dgettext("widget", "New chat"),
        "Your conversations" => dgettext("widget", "Your conversations"),
        "Conversation history" => dgettext("widget", "Conversation history"),
        "No conversations yet." => dgettext("widget", "No conversations yet."),
        "Here to help you find your next step" =>
          dgettext("widget", "Here to help you find your next step"),
        "Assistant is working…" => dgettext("widget", "Assistant is working…"),
        "Close chat" => dgettext("widget", "Close chat"),
        "Conversation" => dgettext("widget", "Conversation"),
        "How can I help?" => dgettext("widget", "How can I help?"),
        "Start a new conversation or choose one from your history." =>
          dgettext("widget", "Start a new conversation or choose one from your history."),
        "Latest messages" => dgettext("widget", "Latest messages"),
        "Assistant" => dgettext("widget", "Assistant"),
        "Writing response" => dgettext("widget", "Writing response"),
        "Working with tools" => dgettext("widget", "Working with tools"),
        "Preparing your answer" => dgettext("widget", "Preparing your answer"),
        "Couldn't finish this response" => dgettext("widget", "Couldn't finish this response"),
        "You can send another message below." =>
          dgettext("widget", "You can send another message below."),
        "Activity needs attention" => dgettext("widget", "Activity needs attention"),
        "Working on your request" => dgettext("widget", "Working on your request"),
        "View response activity" => dgettext("widget", "View response activity"),
        "Response activity" => dgettext("widget", "Response activity"),
        "Tool call" => dgettext("widget", "Tool call"),
        "Tool result" => dgettext("widget", "Tool result"),
        "Reasoning" => dgettext("widget", "Reasoning"),
        "Activity" => dgettext("widget", "Activity"),
        "Running" => dgettext("widget", "Running"),
        "Done" => dgettext("widget", "Done"),
        "Failed" => dgettext("widget", "Failed"),
        "Unknown" => dgettext("widget", "Unknown"),
        "Tool outcome unavailable" => dgettext("widget", "Tool outcome unavailable"),
        "Progress" => dgettext("widget", "Progress"),
        "Error details" => dgettext("widget", "Error details"),
        "Result" => dgettext("widget", "Result"),
        "Waiting for the tool to return a result…" =>
          dgettext("widget", "Waiting for the tool to return a result…"),
        "This step could not be completed." =>
          dgettext("widget", "This step could not be completed."),
        "This step finished without additional output." =>
          dgettext("widget", "This step finished without additional output."),
        "Unable to complete response" => dgettext("widget", "Unable to complete response"),
        "Connection interrupted. Please try again." =>
          dgettext("widget", "Connection interrupted. Please try again."),
        "Submission acknowledgement timed out. Its outcome is unknown. Restore the conversation before sending again." =>
          dgettext(
            "widget",
            "Submission acknowledgement timed out. Its outcome is unknown. Restore the conversation before sending again."
          ),
        "Unable to send. Please try again." =>
          dgettext("widget", "Unable to send. Please try again."),
        "Unable to change conversations." =>
          dgettext("widget", "Unable to change conversations."),
        "Widget unavailable." => dgettext("widget", "Widget unavailable."),
        "No conversation to reopen." => dgettext("widget", "No conversation to reopen."),
        "Conversation switching is unavailable." =>
          dgettext("widget", "Conversation switching is unavailable."),
        "Wait for the current response before switching chats." =>
          dgettext("widget", "Wait for the current response before switching chats."),
        "Conversation unavailable." => dgettext("widget", "Conversation unavailable."),
        "Unable to open this conversation." =>
          dgettext("widget", "Unable to open this conversation."),
        "Wait for the current response or enable multiple conversations." =>
          dgettext("widget", "Wait for the current response or enable multiple conversations."),
        "Invalid widget context." => dgettext("widget", "Invalid widget context."),
        "Reload the widget to change context." =>
          dgettext("widget", "Reload the widget to change context."),
        "Widget context with user_id is required." =>
          dgettext("widget", "Widget context with user_id is required."),
        "Please wait for the current response." =>
          dgettext("widget", "Please wait for the current response."),
        "Enter a message of 1–2000 characters." =>
          dgettext("widget", "Enter a message of 1–2000 characters."),
        "Unable to initialize chat. Please try again." =>
          dgettext("widget", "Unable to initialize chat. Please try again."),
        "Enter a text message." => dgettext("widget", "Enter a text message."),
        "Unable to load conversations. Please try again." =>
          dgettext("widget", "Unable to load conversations. Please try again."),
        "Unable to send your message. Please try again." =>
          dgettext("widget", "Unable to send your message. Please try again.")
      }
    end)
  end

  def messages(messages, locale) do
    Gettext.with_locale(WebWidgetWeb.Gettext, locale, fn ->
      Enum.map(messages, fn message ->
        steps =
          message
          |> Map.get(:steps, [])
          |> Enum.filter(&(Map.get(&1, :kind) in ["tool_call", "tool_result"]))

        completed = Enum.count(steps, &(&1.state == "completed"))
        failed = Enum.count(steps, &(&1.state == "failed"))

        Map.put(message, :activity, %{
          complete:
            dngettext(
              "widget",
              "%{count} step completed",
              "%{count} steps completed",
              length(steps)
            ),
          running:
            dgettext("widget", "%{completed} of %{total} completed",
              completed: completed,
              total: length(steps)
            ),
          failed:
            dgettext("widget", "%{failed} failed · %{completed} completed",
              failed: failed,
              completed: completed
            )
        })
      end)
    end)
  end
end
