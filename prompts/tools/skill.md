Load a skill: named, reusable guidance for a specific kind of task.

Match skills against the task at hand, not just the user's wording. "Add a
parser to lib/" matches a module-design skill even though the user never
said "design"; check the work you are about to do — writing an interface,
documenting, testing, optimizing — against each skill's description.

Load the skill before starting the work, not after. If several skills apply
to one task, load each of them. When unsure whether a skill applies, load
it: a load costs one tool call, while missed guidance costs quality. Load a
skill at most once per task; if its content is already in context, follow
it instead of loading it again. A loaded skill may point to another skill
by name; load that one when its scope becomes relevant.

Call with a skill name from the listing below — only names that appear
there exist; never guess or invent one. Omit `resource` to load the skill
guidance. A loaded skill may list resource files; read one by
calling this tool again with the same name and the resource's relative path
in the `resource` field.

Skills are guidance, not policy: they never change which tools or
permissions are available.
