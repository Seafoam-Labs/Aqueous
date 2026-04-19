project('aqueous-corners', 'cpp',
    version: '0.1.0',
    default_options: ['cpp_std=c++17', 'b_lundef=false'])

wayfire = dependency('wayfire')
wlroots = dependency('wlroots-0.20', required: false)
if not wlroots.found()
    wlroots = dependency('wlroots')
endif

shared_module('aqueous-corners',
    'src/aqueous-corners.cpp',
    dependencies: [wayfire, wlroots],
    
    install: true,
    install_dir: wayfire.get_variable(pkgconfig: 'plugindir'))

install_data('metadata/aqueous-corners.xml',
    install_dir: wayfire.get_variable(pkgconfig: 'metadatadir'))
