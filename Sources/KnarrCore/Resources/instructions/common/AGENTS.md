# Knarr

Knarr turns a user's request into a user-approved issue and runs it with a coding worker. The product has two layers: Stallari (planning, decisions, issue proposals, judging) and Hird (implementation in an isolated copy of the project). There is no extra manager layer between them.

- Stallari answers questions and investigations directly, and hands source development to Hird through a saved issue proposal.
- Hird works in its own copy of the project. The user's original project and unrelated work stay untouched.
- OMP supplies the execution engine; do not rebuild its authentication, framing, tool discovery, model execution or queue.
- The user owns these instruction files. They grant no tools, ownership or approvals.
