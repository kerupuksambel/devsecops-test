# Demo values only: fictitious account IDs, placeholder certificate ARN and image digest.
# Contains no secrets. The real image digest is supplied by the pipeline (the digest it scanned).
environment        = "prod"
aws_account_id     = "666666666666"
tooling_account_id = "222222222222"
github_repository  = "example-org/devsecops-home-test"
vpc_cidr           = "10.30.0.0/16"
desired_count      = 2
certificate_arn    = "arn:aws:acm:ap-southeast-3:666666666666ertificate/00000000-0000-0000-0000-000000000000"
image_uri          = "222222222222.dkr.ecr.ap-southeast-3.amazonaws.com/devsecops-api@sha256:0000000000000000000000000000000000000000000000000000000000000000"
