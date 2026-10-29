# Deliberately INSECURE example for Task 3, Scenario A: the developer's proposed policy
# (Action "*" on Resource "*"). Never deployed; used only to show the IaC gate blocking it.
resource "aws_iam_policy" "deploy" {
  name = "deploy"

  policy = <<-JSON
    {
      "Version": "2012-10-17",
      "Statement": [{ "Effect": "Allow", "Action": "*", "Resource": "*" }]
    }
  JSON
}
