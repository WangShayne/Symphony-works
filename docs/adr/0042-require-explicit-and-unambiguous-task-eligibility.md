# Require explicit and unambiguous task eligibility

Each Automation Project defines eligible Issue states, required opt-in labels, tracker scope, and optional assignee criteria. An Issue enters automation only when exactly one project matches; zero matches are ignored and multiple matches block with an operator alert. The routing model cannot bypass intake eligibility.
