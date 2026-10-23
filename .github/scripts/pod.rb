#!/usr/bin/env ruby

script_dir = File.dirname(File.realpath(__FILE__))
json_version = File.read(File.expand_path('../config/cocoapods-json-version', script_dir)).strip
pod_version = ENV.fetch('COCOAPODS_VERSION')
unless [json_version, pod_version].all? { |version| /\A\d+\.\d+\.\d+\z/.match?(version) }
  abort 'Apple tool dependencies must use exact stable versions'
end
gem 'json', json_version
load Gem.bin_path('cocoapods', 'pod', pod_version)
