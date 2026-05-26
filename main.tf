# All resources are defined in per-domain files at the repo root:
#   project.tf, kms.tf, iam.tf, pubsub.tf, firestore.tf, secrets.tf,
#   functions.tf, scheduler.tf
#
# moved.tf records the address rewrite from the former module-based layout.
# Delete moved.tf after a clean apply confirms 0 to add / 0 to change / 0 to destroy.
