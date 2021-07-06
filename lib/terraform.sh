#!/usr/bin/env bash

# Tell shellcheck we'll be referencing definitions in the source file but don't
# actually source anything as all sourcing takes place up in bin.sh.
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source /dev/null

_tf_global_region="$(config_value terraform.global_region ap-southeast-2)"
_tf_plan_file="${build_dir}/terraform.tfplan"
_tf_state_file="${build_dir}/terraform.tfstate"

# Quieten down Terraform messages.
export TF_IN_AUTOMATION=1

# Expose the global region as a Terraform variable.
export TF_VAR_global_region="${_tf_global_region}"

##
## Initialise Terraform.
##
tf_init() {
  info_msg "Initialising Terraform"

  local backend_bucket
  backend_bucket="terraform-$(current_aws_account_id)"

  rm -rf .terraform/terraform.tfstate .terraform/environment
  terraform init \
    -backend-config=region="${_tf_global_region}" \
    -backend-config=bucket="${backend_bucket}" \
    -backend-config=key=terraform.tfstate \
    -backend-config=dynamodb_table=terraform

  echo
}

##
## Validate the Terraform files.
##
tf_validate() {
  tf_init

  info_msg "Validating Terraform configuration"
  terraform validate
}

##
## Configure the Terraform workspace.
##
tf_workspace() {
  # Ensure that a workspace argument (-w/--workspace) was specified.
  if [[ -z "${_arg_workspace:-}" ]]; then
    die "No Terraform workspace specified. This command requires a --workspace argument."
  fi

  local workspace var_file aws_account_id

  # Locate the workspace in the config file.
  while IFS=$'\t' read -r workspace var_file aws_account_id; do
    if [[ "${_arg_workspace}" == "${workspace}" ]]; then
      # If an AWS account was specified for the workspace, check it against the
      # currently authenticated AWS account.
      if [[ "${aws_account_id}" != null ]]; then
        local current_aws_account_id
        current_aws_account_id="$(current_aws_account_id)"
        if [[ "${aws_account_id}" != "${current_aws_account_id}" ]]; then
          die "The AWS account ID ${aws_account_id} specified for workspace ${_arg_workspace} does not match currently authenticated account ${current_aws_account_id}."
        fi
      fi

      # Initialise Terraform.
      tf_init

      # Select the Terraform workspace.
      info_msg "Selecting Terraform workspace ${_arg_workspace}"
      terraform workspace new "${_arg_workspace}" 2> /dev/null || true
      terraform workspace select "${_arg_workspace}" > /dev/null

      # If a var file has been specified for the workspace then export it using TF_CLI_ARGS so that
      # every terraform invocation doesn't need to know whether to specify it or not.
      if [[ "${var_file}" != null ]]; then
        export TF_CLI_ARGS="-var-file=${var_file}"
      fi

      return 0
    fi
  done < <(jq -r \
    '.terraform.workspaces[]
    | [.name, .var_file // "null", .aws_account_id // "null"]
    | @tsv' <<< "${config_json}")

  # If we've reached here then the specified workspace was not found.
  die "Terraform workspace ${_arg_workspace} does not exist in the config file."
}

##
## Create a Terraform plan.
##
tf_plan() {
  tf_workspace
  mkdir -p "${build_dir}"

  # Create a Terraform plan.
  info_msg "Creating Terraform plan for workspace ${_arg_workspace}"
  terraform plan -out="${_tf_plan_file}"
}

##
## Create a local Terraform plan.
##
tf_plan_local() {
  tf_workspace
  mkdir -p "${build_dir}"

  # Create a local Terraform plan by operating on local state.
  info_msg "Creating local Terraform plan for workspace ${_arg_workspace}"
  terraform state pull > "${_tf_state_file}"
  terraform plan -state="${_tf_state_file}" -lock=false -out="${_tf_plan_file}"
}

##
## Apply a Terraform plan.
##
## This function assumes that a plan file exists at ${_tf_plan_file}.
##
tf_apply() {
  tf_workspace

  # We expect that a plan has already been created.
  if [[ ! -f "${_tf_plan_file}" ]]; then
    die "Terraform plan does not exist. The plan command must be run first."
  fi

  # Apply the Terraform plan
  info_msg "Applying Terraform plan for workspace ${_arg_workspace}"
  terraform apply "${_tf_plan_file}"
}

##
## Refresh the Terraform workspace.
##
tf_refresh() {
  tf_workspace

  info_msg "Refreshing Terraform workspace ${_arg_workspace}"
  terraform refresh
}

##
## Destroy all resources associated with the Terraform workspace. This will prompt the
## user to confirm destruction prior to going ahead.
##
tf_destroy() {
  tf_workspace

  info_msg "Destroying Terraform resources in workspace ${_arg_workspace}"
  TF_IN_AUTOMATION=0 terraform destroy
}

##
## Launch a Terraform console session.
##
tf_console() {
  tf_workspace

  info_msg "Starting Terraform console for workspace ${_arg_workspace}"
  terraform console
}

##
## Lint Terraform files.
##
tf_lint() {
  info_msg "Linting Terraform files"
  terraform fmt -diff -check
}
