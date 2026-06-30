defmodule Vigil.Integrations.Ansible.Normalizer do
  @moduledoc """
  Maps Ansible's `ansible_*` fact namespace onto the platform's common schema
  (ANS-208). The mapped values are co-presented with the raw facts; the raw
  `ansible_*` keys are preserved in full.
  """

  @doc """
  Takes the `ansible_facts` sub-map from `ansible -m setup` output and
  returns a two-key map:
    - `:raw` — the original ansible_facts map (all ansible_* keys)
    - `:normalized` — the mapped platform-schema keys
  """
  @spec normalize(map()) :: %{raw: map(), normalized: map()}
  def normalize(ansible_facts) when is_map(ansible_facts) do
    normalized = %{
      "os.distribution" => ansible_facts["ansible_distribution"],
      "os.distribution.version" => ansible_facts["ansible_distribution_version"],
      "kernel" => ansible_facts["ansible_kernel"],
      "hostname" => ansible_facts["ansible_hostname"],
      "fqdn" => ansible_facts["ansible_fqdn"],
      "ip.addresses" => ansible_facts["ansible_all_ipv4_addresses"],
      "cpu.count" => ansible_facts["ansible_processor_vcpus"],
      "memory.total_mb" => ansible_facts["ansible_memtotal_mb"]
    }

    %{raw: ansible_facts, normalized: normalized}
  end

  def normalize(_), do: %{raw: %{}, normalized: %{}}
end
