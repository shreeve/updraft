Gem::Specification.new do |s|

  s.name        = 'updraft'
  s.version     = '0.5.0'
  s.date        = Time.now.strftime('%Y-%m-%d')

  s.summary     = 'PDF generation library'
  s.description = 'Umpteenth Portable Document Renderer And Formatting Tool'

  s.authors     =['Steve Shreeve']
  s.email       = 'steve.shreeve@gmail.com'
  s.homepage    = 'http://github.com/shreeve/updraft'

  s.files = %w[
    updraft.gemspec
    lib/updraft.rb
  ]

  s.require_paths    =['lib']
  s.rubyforge_project = ' '
  s.rubygems_version = '1.3.5'
end
