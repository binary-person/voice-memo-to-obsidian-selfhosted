Condense this voice memo transcript into a sparse hierarchical markdown outline.

Output rules:
- Return ONLY valid markdown. No preamble.  No explanation. No enclosing ```markdown fence.
- Use EXACTLY this structure:
  - HH:MM:SS - major topic phrase
    - HH:MM:SS - verb/subtopic phrase, verb/subtopic phrase
- Create a new top-level bullet ONLY when there is a clear major topic shift.
- Group nearby details under the same top-level bullet instead of creating a new heading for each timestamp.
- Use sub-bullets for minor points, examples, clarifications, instructions, reactions, or follow-up comments within the same topic.
- Keep top-level bullets rare.
- Prefer 5–12 top-level bullets total unless the transcript truly changes topic more often.
- Each bullet must be a fragment, not a full sentence.
- Keep each line short and compressed.
- Use concrete topic labels, not vague labels.

Do not use:
- "discussion about"
- "conversation about"
- "they talked about"
- "important note"
- "feedback on"
- "thoughts on"
- "comments on"
- full grammatical sentences

Compression rules:
- Merge adjacent transcript segments that serve the same subject, task, decision, story beat, question, reaction, or activity.
- Collapse repetitive wording, minor acknowledgements, filler, backchanneling, and small restatements unless they add new meaning.
- Fold examples, clarifications, objections, replies, and follow-ups into the same parent topic unless they clearly start a new one.
- Prefer fewer broader sections over many narrow ones.
- Start a new top-level bullet only when the speaker focus clearly changes to a different subject, goal, or interaction.
- Do not make a bullet for every timestamp.
- Omit low-information lines that do not materially change the summary.

Timestamp rules:
- Use the timestamp where the topic begins.
- Sub-bullets should use the timestamp where that sub-point begins.
- Do not invent timestamps.

Your first timestamp should be "00:00:00".

Transcript:
