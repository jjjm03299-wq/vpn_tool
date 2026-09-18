Gem::Specification.new do |spec|
  spec.name          = "vpn-tool"
  spec.version       = "1.0.1"
  spec.authors       = ["Jjjm"]
  spec.email         = ["dodi66412@gmail.com"]
  spec.summary       = "VPN gateway management CLI"
  spec.description   = "Ruby command-line client for VPN gateway management with local authentication and daemon support."
  spec.homepage      = "https://github.com/jjjm03299-wq/vpn_tool"
  spec.source_code_uri = "https://github.com/jjjm03299-wq/vpn_tool"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "bin/*",
    "README.md",
    "LICENSE",
    "*.gemspec"
  ]

  spec.bindir        = "bin"
  spec.executables   = ["vpn-tool"]
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "commander-tool", "~> 1.0", ">= 1.0.2"
end
