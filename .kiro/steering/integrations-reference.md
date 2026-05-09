# Integration Tools — Official References

When working on any integration plugin, **always fetch the official documentation** to verify API behaviour, CLI flags, response schemas, and authentication mechanisms. Do not code against assumptions or outdated knowledge.

## How to use this

Before implementing or modifying an integration:
1. Use web search / fetch tools to pull the current official docs for the relevant API or CLI.
2. Verify endpoint paths, required parameters, response shapes, pagination patterns, and error codes against the live documentation.
3. If the docs contradict the spec, surface the discrepancy to the user before proceeding.

## Reference URLs by integration

| Integration | Documentation |
|-------------|---------------|
| **PuppetDB** | https://www.puppet.com/docs/puppetdb/latest/api/index.html |
| **Puppet Server** | https://www.puppet.com/docs/puppet/latest/server/http_api_index.html |
| **Puppet r10k** | https://www.puppet.com/docs/pe/latest/r10k.html |
| **Puppet Code Manager** | https://www.puppet.com/docs/pe/latest/code_mgr.html |
| **Bolt** | https://www.puppet.com/docs/bolt/latest/bolt.html |
| **Ansible** | https://docs.ansible.com/ansible/latest/index.html |
| **Ansible CLI** | https://docs.ansible.com/ansible/latest/cli/ansible.html |
| **AWS EC2** | https://docs.aws.amazon.com/AWSEC2/latest/APIReference/ |
| **AWS SDK (Elixir/Erlang)** | https://github.com/aws-beam/aws-elixir |
| **Azure Compute** | https://learn.microsoft.com/en-us/rest/api/compute/ |
| **Proxmox VE API** | https://pve.proxmox.com/pve-docs/api-viewer/index.html |
| **SSH (Erlang :ssh)** | https://www.erlang.org/doc/apps/ssh/ssh.html |
| **Oban** | https://hexdocs.pm/oban/Oban.html |
| **Phoenix LiveView** | https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html |
| **Ecto** | https://hexdocs.pm/ecto/Ecto.html |

## Rules

- **Never guess API behaviour.** If you're unsure how a PuppetDB query endpoint paginates, or what status codes the Proxmox API returns on auth failure — look it up.
- **Pin to versions where possible.** Note which API version you're coding against (e.g., PuppetDB API v4, AWS EC2 2016-11-15).
- **Document deviations.** If an upstream API behaves differently from what its docs claim, note it in the plugin's code comments and flag it to the user.
- **Check for breaking changes.** Before upgrading a dependency or targeting a new API version, fetch the changelog/migration guide and assess impact.
