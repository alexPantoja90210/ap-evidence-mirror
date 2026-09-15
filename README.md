# ap-evidence-mirror

A static page served from a **private** S3 bucket through CloudFront, where the
bucket refuses direct access and that refusal is demonstrated from outside the
account, with no credentials.

Then the same stack expressed in Terraform by **importing** what the console
built, with an empty plan as the proof that code and account agree.

Tracked as `IA-126`.

## What this is not

It is not the canonical page. The page served here is a **dated mirror** of
<https://alexpantoja90210.github.io/>, which is the copy referenced from my CV
and LinkedIn and the one that stays current. The mirror says so on its face.

It is not a migration, and no published link points at it.

## The claim, and the test

Most published guides for this stack enable S3 static website hosting and make
the bucket public. That works, and it leaves the object store reachable
directly, bypassing the CDN, its logging and its headers.

Here the bucket is private and only this distribution can read it, enforced by a
bucket policy conditioned on the distribution ARN. The service principal
`cloudfront.amazonaws.com` is the same for **every** AWS customer, so that
condition is the only thing between "private origin" and "readable through
somebody else's CDN".

That is falsifiable, and `verify_origin_private.sh` falsifies it:

```bash
./verify_origin_private.sh <bucket> <region> <distribution>.cloudfront.net index.html
```

It refuses to run if AWS credentials are present in the environment, because the
question is what an outsider can reach.

### Why it reports three outcomes and not two

On a bucket with Block Public Access enabled, **S3 answers 403 for an object
that does not exist**, exactly as it does for one that exists and is denied. It
does this on purpose, so nobody can enumerate a bucket by probing.

So a bare 403 proves nothing: a typo in the bucket name, the wrong region, or a
bucket that was never created all produce it. The script reports
`INCONCLUSIVE` in that case rather than converting an ambiguous reading into a
pass.

The ambiguity is resolved by making the check go red on purpose:

| Reading | Result |
| --- | --- |
| origin, real key | 403 |
| origin, key that cannot exist | 403 |
| CDN, real key | 200 |
| **origin, a throwaway object made public deliberately** | **200** |
| origin, same object after reverting | 403 |

The fourth reading is the one that matters. It is what turns the 403 into a
**denial** rather than a number. Without it there are four coherent figures and
no conclusion.

## Infrastructure as code, in the harder direction

The Terraform in this repository describes the stack that the console built.
The resources were **imported**, not recreated, and the acceptance criterion was
`terraform plan` reporting no changes.

The first plan showed nine differences. Seven were the code being wrong about
the account; two were deliberate improvements. One of the seven was
`is_ipv6_enabled = true -> false`: the console had enabled IPv6, the provider
default is false, and applying without reading would have silently disabled it
on a working distribution.

Reaching an empty plan is not a formality. It is what stops the code from
quietly degrading the thing it claims to describe.

Two things the module deliberately does **not** do:

- **It never contains the AWS account id.** The policy needs the distribution
  ARN, which carries it, so the module reads it at plan time via
  `aws_caller_identity`. The file is publishable unchanged.
- **It does not hardcode the cache policy id.** It looks the policy up by name,
  because a wrong name fails loudly while a wrong id would point silently at a
  different policy.

## Running it

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform validate
terraform plan -out=tfplan                     # read every line
terraform apply tfplan
```

Applying a **saved** plan rather than re-planning at apply time is deliberate: a
plan that was reviewed and an apply that does something else is not plan-first.

## What is out of scope, and why

**Route 53 and a custom domain.** A public hosted zone is $0.50/month and is not
in the free tier, plus an annual registration. S3 and CloudFront fit inside the
free plan. The one service that would have cost money is the one that was cut.

**AWS WAF.** The CloudFront console defaults *Security protections* to enabled,
which provisions a web ACL at $5/month, on the same review screen that estimates
$0/month. A WAF in front of a CDN serving one static HTML file protects nothing:
no form, no login, no API. Disabled, and recorded as a finding.

**Standard logging.** Off, to avoid the storage cost. Worth stating plainly,
because one argument for a private origin is that all traffic passes through the
CDN *and is recorded there*, and only the first half of that sentence is
currently true of this stack.

**Deployment automation.** A manual sync is in scope; CI is not.

## Contents

| Path | What it is |
| --- | --- |
| `index.html` | The mirrored page, banner and date included |
| `verify_origin_private.sh` | The probe, including the red check |
| `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf` | Terraform for the bucket, the policy, the OAC and the distribution |

Personal, independent work. Not a delivery to any client or employer.
