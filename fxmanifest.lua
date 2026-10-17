fx_version 'cerulean'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
game 'rdr3'

description 'rsg-ranch'
version '3.1.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'client/menu.lua',
    'client/client.lua',
    'client/npcs.lua',
    'client/modules/*.lua',
    'client/exports.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/server.lua',
    'server/modules/orders.lua',
    'server/modules/wellpump.lua',
    'server/modules/admin.lua',
    'server/versionchecker.lua',
    'server/exports.lua'
}

dependencies {
    'rsg-core',
    'rsg-inventory',
    'rsg-multijob',
    'ox_lib',
    'ox_target',
    'oxmysql',
}

ui_page 'html/index.html'

files {
    'locales/*.json',
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'html/admin.js',
}

lua54 'yes'

escrow_ignore {
    'html/*',
    'installation/*',
    'locales/*',
    'shared/*',
    'README.md'
}
