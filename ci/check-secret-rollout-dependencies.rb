#!/usr/bin/env ruby

require "open3"
require "yaml"

chart = ARGV.fetch(0, File.expand_path("../charts/logfire", __dir__))
command = [
  "helm", "template", "secret-rollout-check", chart,
  "--namespace", "default",
  "--set-string", "adminEmail=test@example.com",
  "--set-string", "objectStore.uri=s3://test-bucket",
  "--set", "dev.deployPostgres=true",
  "--set", "logfire-ai-gateway.enabled=true",
  "--set", "logfire-remote-mcp.enabled=true",
  "--set", "logfire-ff-query-worker.enabled=true",
]

rendered, status = Open3.capture2e(*command)
abort rendered unless status.success?

def checksum_for(workload, reference)
  name = reference.fetch("name")
  key = reference.fetch("key")

  case key
  when "postgresDsn"
    "checksum/logfire-postgres-dsn"
  when "postgresFFDsn"
    workload == "logfire-ff-crud-api" ? "checksum/logfire-postgres-dsn" : "checksum/logfire-postgres-ff-dsn"
  when "key"
    name.end_with?("gateway-encryption") ? "checksum/gateway-encryption" : "checksum/#{key}"
  when "internalSecret"
    name.end_with?("gateway-internal-secret") ? "checksum/gateway-internal-secret" : "checksum/#{key}"
  else
    "checksum/#{key}"
  end
end

missing = []
references = 0

YAML.load_stream(rendered).compact.each do |resource|
  next unless %w[Deployment StatefulSet DaemonSet].include?(resource["kind"])

  workload = resource.dig("metadata", "name")
  pod = resource.dig("spec", "template") || {}
  annotations = pod.dig("metadata", "annotations") || {}
  containers = Array(pod.dig("spec", "containers")) + Array(pod.dig("spec", "initContainers"))

  containers.each do |container|
    Array(container["env"]).each do |env|
      reference = env.dig("valueFrom", "secretKeyRef")
      next unless reference

      references += 1
      checksum = checksum_for(workload, reference)
      missing << "#{workload}: #{reference.fetch("name")}/#{reference.fetch("key")} needs #{checksum}" unless annotations.key?(checksum)
    end
  end
end

abort "No environment Secret references were rendered" if references.zero?
abort "Missing Secret rollout dependencies:\n- #{missing.join("\n- ")}" unless missing.empty?

puts "Verified #{references} environment Secret references have rollout checksums"
