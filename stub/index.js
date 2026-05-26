// Placeholder Cloud Function source. Real source is deployed by
// `gcloud functions deploy <name> --source=./functions` from the
// functions/ workspace in the SiveraV2 repo.
//
// The Terraform module ignores future drift on build_config.source so
// this stub does not overwrite production deploys.
exports.handler = (req, res) => {
  res.status(503).send("stub: deploy real source via gcloud");
};
