# Grok Bot

Grok Bot has no local plugin. Its [inference hooks](https://docs.x.ai/grok-bot/inference-hooks) call Rogue directly from the Grok Bot backend, so a Cursor team admin connects the whole team once and nothing is installed on members' machines.

## Set up

You need a team admin on a Cursor Enterprise team and a Rogue API key from `https://app.rogue.security/settings/api-keys`.

1. In the Cursor dashboard, open [Inference Hooks](https://cursor.com/dashboard/bot/inference-hooks) from the **Security & Compliance** section of the Grok Bot page.
2. Click **Set Up Endpoint** and choose **Custom Endpoint**.
3. Set **Endpoint URL** to `https://api.rogue.security/api/v1/hooks/grok-bot`.
4. Add the custom header `X-Rogue-Api-Key` (or `X-Api-Key`) with your Rogue API key, then save. Rogue doesn't use the signing secret Cursor shows.
5. Click **Test Connection**. Rogue allows test requests without recording them.
6. Turn on **Enforce Verdicts** and **Validate Tool Calls**. Start in **Shadow Mode**, then pick **Allow the Request** (fail open) or **Block the Request** (fail closed).

Rogue evaluates new member messages, tool calls and returned tool results against your AI DR coding-agent controls and policies. A deny returns Rogue's reason to the member. Sessions appear in AI DR as Grok Bot, one per Bot and member.

Full guide: Rogue docs, Integrations, Coding agents, Grok Bot.
