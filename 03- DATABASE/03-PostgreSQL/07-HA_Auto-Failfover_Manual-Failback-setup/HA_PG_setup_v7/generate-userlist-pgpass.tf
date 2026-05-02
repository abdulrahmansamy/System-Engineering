
# "wso2_user" "md5${wso2user_md5}"
# "tms_user" "md5${tmsuser_md5}"
# "exam_user" "md5${examuser_md5}"
# "helpdesk_user" "md5${helpdeskuser_md5}"
# "kong_user" "md5${konguser_md5}"

locals {
  postgres_md5 = "md5${md5("${random_password.pg_superuser.result}postgres")}"
  examuser_md5 = "md5${md5("${random_password.pg_examuser.result}exam_user")}"
  tmsuser_md5  = "md5${md5("${random_password.pg_tmsuser.result}tms_user")}"
  wso2user_md5 = "md5${md5("${random_password.pg_wso2user.result}wso2_user")}"
  helpdeskuser_md5 = "md5${md5("${random_password.pg_helpdeskuser.result}helpdesk_user")}"
  konguser_md5 = "md5${md5("${random_password.pg_konguser.result}kong_user")}"
}

resource "local_file" "pgbouncer_userlist" {
  filename        = ".secrets/pgbouncer_userlist.txt" # should be deployed in /etc/pgbouncer/userlist.txt on the instance
  file_permission = "0600"

  content = <<EOT
"postgres" "${local.postgres_md5}"
"tms_user" "${local.tmsuser_md5}"
"exam_user" "${local.examuser_md5}"
"wso2_user" "${local.wso2user_md5}"
"helpdesk_user" "${local.helpdeskuser_md5}"
"kong_user" "${local.konguser_md5}"
EOT
}

resource "local_file" "pgpass_file" {
  filename        = ".secrets/.pgpass" # should be deployed in /var/lib/postgresql/.pgpass on the instance
  file_permission = "0600"

  content = <<EOT
*:5432:*:postgres:${random_password.pg_superuser.result}
*:5432:*:tms_user:${random_password.pg_tmsuser.result}
*:5432:*:exam_user:${random_password.pg_examuser.result}
*:5432:*:wso2_user:${random_password.pg_wso2user.result}
*:5432:*:helpdesk_user:${random_password.pg_helpdeskuser.result}
*:5432:*:kong_user:${random_password.pg_konguser.result}
EOT
}

/* To only target the generation of userlist and pgpass files, run: 
terraform plan \
  -target=google_secret_manager_secret_version.pg_tmsuser \
  -target=google_secret_manager_secret_version.pg_examuser \
  -target=google_secret_manager_secret_version.pg_wso2user \
  -target=google_secret_manager_secret_version.pg_helpdeskuser \
  -target=google_secret_manager_secret_version.pg_konguser \
  -target=local_file.pgbouncer_userlist \
  -target=local_file.pgpass_file

terraform apply \
  -target=google_secret_manager_secret_version.pg_tmsuser \
  -target=google_secret_manager_secret_version.pg_examuser \
  -target=google_secret_manager_secret_version.pg_wso2user \
  -target=google_secret_manager_secret_version.pg_helpdeskuser \
  -target=google_secret_manager_secret_version.pg_konguser \
  -target=local_file.pgbouncer_userlist \
  -target=local_file.pgpass_file

terraform plan \
  -target=google_secret_manager_secret_version.pg_superuser \
  -target=local_file.pgbouncer_userlist \
  -target=local_file.pgpass_file
*/