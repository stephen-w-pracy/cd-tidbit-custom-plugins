# Narrator Script — Custom Plugins

Read this aloud while performing the actions described in brackets. Each act maps to [production-spec.md](./production-spec.md).

> Version numbers like `v3` and column ids like `<dev-col-id>` are illustrative placeholders. Read the real values off the screen at recording time — the demo card you see may have a different id than the one you rehearsed with.

---

## Act 1 — Overview and Setup (2–3 min)

### Narration

> Harness plugins are documented under Continuous Integration, but they're just as useful in CD. This tidbit shows how — using a small containerized plugin that talks to Kanboard and moves a card across the board every time we deploy.

**[On-screen action: pipeline canvas with four stages — Build App Image, Deploy to Dev, Deploy to QA, Deploy to Prod. Kanboard tab open in a second panel showing a "Deployments" project with one task in the Backlog column.]**

> Here's the setup. On the left, a Harness CD pipeline that builds a Python web app and rolls it out to three environments — Dev, QA, and Prod. On the right, a Kanboard board with a single task sitting in Backlog. Our goal for the next ten minutes: extend each deploy stage with a plugin step that reaches into Kanboard, moves that task to the matching column, and posts a comment linking back to the Harness execution.

**[Switch briefly to a terminal showing the project tree — highlight `plugin/`, `.harness/`, and `k8s/`.]**

> The repo has everything you need to reproduce this in your own Harness account: the pipeline YAML, the plugin's Dockerfile and Python source, and a setup script that provisions the whole thing end-to-end.

---

## Act 2 — Tour the plugin and the board (2–3 min)

### Narration

> Before we run anything, let's look at what a plugin actually *is*.

**[Open `plugin/entrypoint.py` in the editor. Highlight the module docstring, then scroll to the env-var reads.]**

> This is the entire plugin. Thirty lines of Python. It reads a handful of environment variables — all prefixed `PLUGIN_` — makes two Kanboard API calls, and exits. The `PLUGIN_` prefix is a Drone plugin convention: Harness inherits it, so any key you put under `settings:` in your pipeline arrives inside the container prefixed with `PLUGIN_`.

**[Scroll down to the `kb.move_task_position(...)` call and the `kb.create_comment(...)` call. Highlight both.]**

> Two calls. The first moves the demo task to the column for this environment. The second posts a comment on the task with the app version, the image, and a clickable link back to the Harness execution — free traceability, one API call.

**[Open `plugin/Dockerfile`.]**

> The Dockerfile is four lines. Python base image, `pip install kanboard`, copy the entrypoint in, done.

**[Switch to the Harness UI. Open the **Build Kanboard Plugin** pipeline. Point at the single CI stage and its `BuildAndPushDockerRegistry` step.]**

> That Dockerfile is built by a separate short pipeline — **Build Kanboard Plugin**. One CI stage, one step, running on Harness Cloud. No local `docker` required. It pushes the image to GHCR tagged `latest` and with a sequence number. You run this once after setup, and again whenever the plugin changes.

**[Open `.harness/pipeline.yaml` (or the YAML view in Harness) scrolled to the Dev stage's `stepGroup`. Highlight the `stepGroupInfra` block, the Plugin step's `image:`, and the `settings:` map.]**

> And here's where the CD side gets interesting. This is the Dev stage of the main pipeline. See the `stepGroup` wrapping the Plugin step? That wrapper is the CD-specific bit. In a CI stage, you'd drop a Plugin step in directly — the CI runtime spins up your container for you. A CD Deployment stage has no built-in runtime, so a bare Plugin step won't start. The fix is this `stepGroupInfra: KubernetesDirect` block: it tells Harness which cluster and namespace to launch the plugin container in. Small change, easy to miss in the docs.

**[Zoom in on the `settings:` map.]**

> Inside the Plugin step, everything else looks like a standard CI plugin. `image:` points at our GHCR-hosted plugin. `settings:` is a map of key-value pairs that Harness turns into env vars. Two things worth calling out: the secret reference — `<+secrets.getValue("kanboard_api_token")>` — is the standard Harness syntax, works for any step type; and `KANBOARD_COL: <+env.variables.column_id>` is how the *same* image targets a *different* column in each stage. One image, three runs, three different columns.

**[Point at the `plugin_image` pipeline variable at the top of the YAML.]**

> One footnote on the image tag. This pipeline pulls the plugin as `:latest`. In a demo that's fine — but in production you'd tighten this up, either by exposing the tag as a runtime input, pinning to a content digest, or having the plugin build pipeline push its tag into this variable via a trigger. The README covers the trade-off.

**[Switch to the Kanboard tab. Pan across the four columns and settle on the Backlog card.]**

> And here's the board. One project called Deployments, four columns — Backlog, Dev, QA, Prod — and one task sitting in Backlog, ready to move.

---

## Act 3 — Run the pipeline; Build + Dev stage (2–3 min)

### Narration

**[Click **Run** on the **Build and Deploy Demo App** pipeline. Open the execution view.]**

> Let's run it.

**[Wait for the **Build App Image** stage to progress. Show the build logs; highlight the tag in the push output.]**

> First stage is Build App Image. This is a CI stage — Harness Cloud builds our Python web app from `app/Dockerfile` and pushes it tagged `v` plus the pipeline's sequence id. That tag flows into the deploy stages as an artifact.

**[Pipeline advances to Deploy to Dev. Switch to the Dev browser tab at http://127.0.0.1:8080 as the rolling deploy completes.]**

> Deploy to Dev picks up the new tag and rolls it into the `web-dev` namespace. Refresh the Dev tab — new version, blue badge.

**[Switch back to the execution view. Wait for the **Kanboard Notification** step group to run and complete. Click into the Plugin step.]**

> Now the Kanboard Notification step group runs. That's the wrapper we looked at — Harness spins up a fresh plugin container in the cluster, runs it, tears it down. The plugin makes its two API calls, exits zero, and…

**[Switch to the Kanboard tab. Card has moved from Backlog to Dev. Click into the card and expand the comments section to show the new comment.]**

> …the card moves to the Dev column. And when we open the task, there's the comment — app version, image, and a link back to the Harness execution we just ran. Traceability from your board straight into Harness, in one plugin call.

**[Back to the execution view. Hover over the Plugin step to show the resolved env vars.]**

> Hover the step in the execution view and you can see the exact env vars Harness injected — useful when you're debugging.

---

## Act 4 — QA stage (2–3 min)

### Narration

**[Pipeline advances to Deploy to QA. Show the QA browser tab at http://127.0.0.1:8081 rolling to the new tag — orange badge.]**

> Same pipeline, next stage. QA picks up the same artifact that Dev just deployed — `useFromStage` — rolls it into the `web-qa` namespace, and the QA badge turns orange.

**[Switch to the Kanboard tab. Card hops from Dev to QA. Open the task and show the new comment appended below the Dev comment.]**

> Kanboard Notification runs again. Card hops Dev to QA, and a second comment lands on the task — same format, updated `ENV_NAME`, same execution link.

**[Open the QA stage's Plugin step settings side-by-side with the Dev stage's Plugin step settings. Point at `KANBOARD_COL`.]**

> This is the payoff for the per-environment parameter. Same plugin image, same `settings:` map — but `KANBOARD_COL` resolves to a different column id per stage because each environment carries its own `column_id` variable. The plugin doesn't know or care which stage it's in; the environment tells it where to move the card.

---

## Act 5 — Prod stage (2–3 min)

### Narration

**[Pipeline advances to Deploy to Prod. Show Prod browser tab at http://127.0.0.1:8082 — green badge. Pipeline finishes green.]**

> Prod deploy rolls. Badge turns green. And the plugin runs a third and final time.

**[Switch to Kanboard. Card hops from QA to Prod. Open the task; three comments now — Dev, QA, Prod. Pan across the board to show the completed journey.]**

> Card lands in Prod. Three comments on the task, one per stage — a full audit trail of what deployed where, with a link back to Harness for each one.

**[Widen the Kanboard view to show all four columns.]**

> So — five things in ten minutes. A containerized Plugin step. The Container Step Group wrapper that makes it work in a CD stage. The image built by its own short CI pipeline. Secrets injected via `<+secrets.getValue>`. And per-environment parameters that let one image do three different jobs across the pipeline.

**[Switch to the README's "Future Enhancements" section.]**

> The README has a "Future Enhancements" section for what to try next — gating the plugin behind an approval, triggering the pipeline from Kanboard events, tightening the plugin tag for production use. Give it a look.

---

## Closing

> That's Custom Plugins in Harness CD. Try it yourself — the repo at github.com/stephen-w-pracy/cd-tidbit-custom-plugins has everything you need.
