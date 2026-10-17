# The -browse firewall follows the profile's port_forwards (#322). Plan-only against a
# mocked google provider: no credentials, no cloud calls. Run by `tofu test` from the
# module dir (scripts/bin/validate-custom).

mock_provider "google" {}

variables {
  name          = "vrg-test"
  zone          = "us-central1-a"
  instance_type = "n2-standard-8"
  volume_id     = "projects/p/zones/us-central1-a/disks/vrg-test-data"
  ssh_user      = "vergil"
  # Shaped like vergil-tooling's render_provision_env: shlex-quoted, one key per line.
  provision_env = "EXTRA_PACKAGES=''\nPORT_FORWARDS='3000|192.168.5.2:3000;9443|127.0.0.1:19443'\nNESTED_VIRT=true\nVERGIL_USER=vergil\nHOME=/home/vergil"
}

run "opens_every_forward_host_port" {
  command = plan

  assert {
    condition     = length(google_compute_firewall.browse) == 1
    error_message = "a profile with port_forwards must get exactly one browse rule"
  }
  assert {
    condition     = tolist(google_compute_firewall.browse[0].allow)[0].ports == tolist(["3000", "9443"])
    error_message = "browse rule must open exactly the forward host ports 3000 and 9443"
  }
  assert {
    condition     = tolist(google_compute_firewall.browse[0].allow)[0].protocol == "tcp"
    error_message = "browse rule must be tcp"
  }
  assert {
    condition     = google_compute_firewall.browse[0].source_ranges == toset(["0.0.0.0/0"])
    error_message = "browse rule keeps the 0.0.0.0/0 source range (#260)"
  }
  assert {
    condition     = tolist(google_compute_firewall.ssh.allow)[0].ports == tolist(["22"]) && google_compute_firewall.ssh.source_ranges == toset(["35.235.240.0/20"])
    error_message = "SSH must stay tcp:22 from the IAP range only"
  }
}

run "single_forward" {
  command = plan
  variables {
    provision_env = "PORT_FORWARDS='5601|127.0.0.1:15601'\nVERGIL_USER=vergil"
  }
  assert {
    condition     = tolist(google_compute_firewall.browse[0].allow)[0].ports == tolist(["5601"])
    error_message = "a single forward opens only its host port (no hardcoded 3000)"
  }
}

run "duplicate_and_zero_padded_ports_collapse" {
  command = plan
  variables {
    provision_env = "PORT_FORWARDS='3000|a:1;03000|b:2;3000|c:3'"
  }
  assert {
    condition     = tolist(google_compute_firewall.browse[0].allow)[0].ports == tolist(["3000"])
    error_message = "repeated host ports must be opened once"
  }
}

run "no_forwards_opens_nothing" {
  command = plan
  variables {
    provision_env = "EXTRA_PACKAGES=''\nPORT_FORWARDS=''\nVERGIL_USER=vergil"
  }
  assert {
    condition     = length(google_compute_firewall.browse) == 0
    error_message = "no port_forwards must create no browse rule (an empty ports list would admit every port)"
  }
}

run "missing_port_forwards_fails" {
  command = plan
  variables {
    provision_env = "EXTRA_PACKAGES=''\nVERGIL_USER=vergil"
  }
  expect_failures = [google_compute_instance.vm]
}

run "port_22_rejected" {
  command = plan
  variables {
    provision_env = "PORT_FORWARDS='3000|a:1;22|127.0.0.1:2222'"
  }
  expect_failures = [google_compute_instance.vm]
}

run "non_numeric_port_rejected" {
  command = plan
  variables {
    provision_env = "PORT_FORWARDS='grafana|127.0.0.1:3000'"
  }
  expect_failures = [google_compute_instance.vm]
}

run "out_of_range_port_rejected" {
  command = plan
  variables {
    provision_env = "PORT_FORWARDS='70000|127.0.0.1:3000'"
  }
  expect_failures = [google_compute_instance.vm]
}
