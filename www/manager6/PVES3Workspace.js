// Copyright (C) 2026 pve-s3 contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
// Datacenter -> S3 Object Storage, grouped like Permissions:
// one parent page (status, itemId 's3', expandedOnInit)
// plus one grid page per section tagged groups: ['s3'].
// Each page is its own class; the Datacenter config
// panel provides the left nav and the toolbar title.

Ext.define('PVE.dc.S3KeyWindow', {
    extend: 'Ext.window.Window',
    alias: 'widget.pveDcS3KeyWindow',

    title: gettext('Access Key Created'),
    modal: true,
    width: 560,
    layout: 'fit',

    // { 'access-key': ..., 'secret-key': ... }
    keydata: undefined,

    initComponent: function() {
        let me = this;
        let k = me.keydata || {};
        me.items = [{
            xtype: 'form',
            bodyPadding: 10,
            border: false,
            items: [
                {
                    xtype: 'component',
                    html: '<b>' + Ext.htmlEncode(gettext(
                        'Copy the secret key now. It is shown ' +
                        'once and cannot be displayed again.'))
                        + '</b>',
                    padding: '0 0 10 0',
                },
                {
                    xtype: 'textfield',
                    fieldLabel: gettext('Access Key'),
                    labelWidth: 120,
                    value: k['access-key'] || '',
                    readOnly: true,
                    selectOnFocus: true,
                    anchor: '100%',
                },
                {
                    xtype: 'textfield',
                    fieldLabel: gettext('Secret Key'),
                    labelWidth: 120,
                    value: k['secret-key'] || '',
                    readOnly: true,
                    selectOnFocus: true,
                    anchor: '100%',
                },
            ],
            buttons: [{
                text: gettext('OK'),
                handler: function() { me.close(); },
            }],
        }];
        me.callParent();
    },
});

Ext.define('PVE.dc.S3CreateUserWindow', {
    extend: 'Ext.window.Window',
    alias: 'widget.pveDcS3CreateUserWindow',

    title: gettext('Create S3 User'),
    modal: true,
    width: 480,
    layout: 'fit',
    onDone: undefined,
    // preset tenant (from the Tenants page); locks the field
    tenantValue: undefined,

    initComponent: function() {
        let me = this;
        let form = Ext.create('Ext.form.Panel', {
            bodyPadding: 10,
            border: false,
            fieldDefaults: { labelWidth: 150, anchor: '100%' },
            items: [
                {
                    xtype: 'textfield',
                    name: 'uid',
                    fieldLabel: gettext('User ID'),
                    allowBlank: false,
                },
                {
                    xtype: 'textfield',
                    name: 'display-name',
                    fieldLabel: gettext('Display Name'),
                },
                {
                    xtype: 'combobox',
                    name: 'tenant',
                    fieldLabel: gettext('Tenant (Pool)'),
                    store: Ext.create('Ext.data.Store', {
                        fields: ['tenant'],
                        proxy: {
                            type: 'proxmox',
                            url: '/api2/json/cluster/s3/tenants',
                        },
                        autoLoad: true,
                    }),
                    displayField: 'tenant',
                    valueField: 'tenant',
                    queryMode: 'local',
                    editable: true,
                    forceSelection: true,
                    allowBlank: false,
                    value: me.tenantValue || undefined,
                    readOnly: !!me.tenantValue,
                },
            ],
            buttons: [
                {
                    text: gettext('Cancel'),
                    handler: function() { me.close(); },
                },
                {
                    text: gettext('Create'),
                    formBind: true,
                    handler: function() {
                        PVE.s3.API.request({
                            url: '/cluster/s3/users',
                            method: 'POST',
                            params: form.getValues(),
                            waitMsgTarget: me,
                            success: function(r) {
                                let keys = (r.result.data || {}).keys || [];
                                me.close();
                                if (me.onDone) { me.onDone(); }
                                if (keys.length) {
                                    Ext.create('PVE.dc.S3KeyWindow', {
                                        keydata: keys[0],
                                    }).show();
                                }
                            },
                        });
                    },
                },
            ],
        });
        me.items = [form];
        me.callParent();
    },
});

Ext.define('PVE.dc.S3CreateBucketWindow', {
    extend: 'Ext.window.Window',
    alias: 'widget.pveDcS3CreateBucketWindow',

    title: gettext('Create Bucket'),
    modal: true,
    width: 480,
    layout: 'fit',
    onDone: undefined,

    initComponent: function() {
        let me = this;
        let form = Ext.create('Ext.form.Panel', {
            bodyPadding: 10,
            border: false,
            fieldDefaults: { labelWidth: 150, anchor: '100%' },
            items: [
                {
                    xtype: 'textfield',
                    name: 'bucket',
                    fieldLabel: gettext('Bucket'),
                    allowBlank: false,
                },
                {
                    xtype: 'combobox',
                    name: 'uid',
                    fieldLabel: gettext('Owner'),
                    store: Ext.create('Ext.data.Store', {
                        fields: ['uid', 'tenant'],
                        proxy: {
                            type: 'proxmox',
                            url: '/api2/json/cluster/s3/users',
                        },
                        autoLoad: true,
                    }),
                    displayField: 'uid',
                    valueField: 'uid',
                    queryMode: 'local',
                    editable: true,
                    forceSelection: true,
                    allowBlank: false,
                    listeners: {
                        change: function(combo, uid) {
                            let rec = combo.getStore().findRecord('uid', uid);
                            let tf = combo.up('form').down('[name=tenant]');
                            if (rec && tf) { tf.setValue(rec.get('tenant')); }
                        },
                    },
                },
                {
                    xtype: 'textfield',
                    name: 'tenant',
                    fieldLabel: gettext('Tenant (Pool)'),
                    readOnly: true,
                    allowBlank: false,
                },
            ],
            buttons: [
                {
                    text: gettext('Cancel'),
                    handler: function() { me.close(); },
                },
                {
                    text: gettext('Create'),
                    formBind: true,
                    handler: function() {
                        PVE.s3.API.request({
                            url: '/cluster/s3/buckets',
                            method: 'POST',
                            params: form.getValues(),
                            waitMsgTarget: me,
                            success: function() {
                                me.close();
                                if (me.onDone) { me.onDone(); }
                            },
                        });
                    },
                },
            ],
        });
        me.items = [form];
        me.callParent();
    },
});

Ext.define('PVE.dc.S3CreateTenantWindow', {
    extend: 'Ext.window.Window',
    alias: 'widget.pveDcS3CreateTenantWindow',

    title: gettext('Create Tenant (PVE Pool)'),
    modal: true,
    width: 480,
    layout: 'fit',
    onDone: undefined,

    initComponent: function() {
        let me = this;
        let form = Ext.create('Ext.form.Panel', {
            bodyPadding: 10,
            border: false,
            fieldDefaults: { labelWidth: 150, anchor: '100%' },
            items: [{
                xtype: 'textfield',
                name: 'tenant',
                fieldLabel: gettext('Tenant / Pool'),
                allowBlank: false,
            }],
            buttons: [
                {
                    text: gettext('Cancel'),
                    handler: function() { me.close(); },
                },
                {
                    text: gettext('Create'),
                    formBind: true,
                    handler: function() {
                        PVE.s3.API.request({
                            url: '/cluster/s3/tenants',
                            method: 'POST',
                            params: form.getValues(),
                            waitMsgTarget: me,
                            success: function() {
                                me.close();
                                if (me.onDone) { me.onDone(); }
                            },
                        });
                    },
                },
            ],
        });
        me.items = [form];
        me.callParent();
    },
});

Ext.define('PVE.dc.S3KeysWindow', {
    extend: 'Ext.window.Window',
    alias: 'widget.pveDcS3KeysWindow',

    title: gettext('Access Keys'),
    modal: true,
    width: 640,
    height: 320,
    layout: 'fit',

    // uid and tenant of the user whose keys are shown
    uid: undefined,
    tenant: undefined,

    initComponent: function() {
        let me = this;
        me.title = gettext('Access Keys') + ': '
            + (me.tenant ? me.tenant + '$' : '') + me.uid;
        let store = Ext.create('Ext.data.Store', {
            fields: ['access-key', 'created', 'active'],
            proxy: {
                type: 'proxmox',
                url: '/api2/json/cluster/s3/users/keys',
                extraParams: { uid: me.uid, tenant: me.tenant || undefined },
            },
            autoLoad: true,
        });
        let sm = Ext.create('Ext.selection.RowModel', {});
        let createKey = function(done) {
            PVE.s3.API.request({
                url: '/cluster/s3/users/key',
                method: 'POST',
                params: { uid: me.uid, tenant: me.tenant || undefined },
                success: function(r) {
                    store.load();
                    Ext.create('PVE.dc.S3KeyWindow', {
                        keydata: r.result.data,
                    }).show();
                    if (done) { done(r.result.data); }
                },
            });
        };
        me.items = [{
            xtype: 'gridpanel',
            store: store,
            selModel: sm,
            border: false,
            columns: [
                { header: gettext('Access Key'), dataIndex: 'access-key', flex: 1 },
                { header: gettext('Created'), dataIndex: 'created', width: 200 },
                {
                    header: gettext('Active'), dataIndex: 'active', width: 80,
                    renderer: function(v) { return v ? gettext('Yes') : gettext('No'); },
                },
            ],
            tbar: [
                {
                    text: gettext('Create Key'),
                    iconCls: 'fa fa-plus-circle',
                    handler: function() { createKey(); },
                },
                {
                    text: gettext('Rotate Key'),
                    iconCls: 'fa fa-refresh',
                    disabled: true,
                    selModel: sm,
                    enableFn: function(rec) { return !!rec; },
                    handler: function() {
                        let rec = sm.getSelection()[0];
                        if (!rec) { return; }
                        let oldKey = rec.get('access-key');
                        Ext.Msg.confirm(gettext('Confirm'),
                            gettext('Create a new key and revoke ')
                                + oldKey + '? Update clients with the '
                                + 'new secret first if they are active.',
                            function(answer) {
                                if (answer !== 'yes') { return; }
                                createKey(function() {
                                    PVE.s3.API.request({
                                        url: '/cluster/s3/users/key',
                                        method: 'DELETE',
                                        params: {
                                            uid: me.uid,
                                            'access-key': oldKey,
                                            tenant: me.tenant || undefined,
                                        },
                                        success: function() { store.load(); },
                                    });
                                });
                            });
                    },
                },
                {
                    text: gettext('Revoke Key'),
                    iconCls: 'fa fa-trash-o',
                    disabled: true,
                    selModel: sm,
                    enableFn: function(rec) { return !!rec; },
                    handler: function() {
                        let rec = sm.getSelection()[0];
                        if (!rec) { return; }
                        Ext.Msg.confirm(gettext('Confirm'),
                            gettext('Revoke key ') + rec.get('access-key') + '?',
                            function(answer) {
                                if (answer !== 'yes') { return; }
                                PVE.s3.API.request({
                                    url: '/cluster/s3/users/key',
                                    method: 'DELETE',
                                    params: {
                                        uid: me.uid,
                                        'access-key': rec.get('access-key'),
                                        tenant: me.tenant || undefined,
                                    },
                                    success: function() { store.load(); },
                                });
                            });
                    },
                },
                '->',
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-refresh',
                    handler: function() { store.load(); },
                },
            ],
        }];
        me.callParent();
    },
});

Ext.define('PVE.dc.S3ObjectsWindow', {
    extend: 'Ext.window.Window',
    alias: 'widget.pveDcS3ObjectsWindow',

    title: gettext('Objects'),
    modal: true,
    width: 760,
    height: 460,
    layout: 'fit',

    bucket: undefined,

    initComponent: function() {
        let me = this;
        me.title = gettext('Objects') + ': ' + me.bucket;
        let prefixField = Ext.create('Ext.form.field.Text', {
            fieldLabel: gettext('Prefix'),
            labelWidth: 50,
            flex: 1,
        });
        let store = Ext.create('Ext.data.Store', {
            fields: ['key', 'type', 'size', 'modified', 'storage'],
            proxy: {
                type: 'proxmox',
                url: '/api2/json/cluster/s3/buckets/objects',
                extraParams: { bucket: me.bucket, delimiter: '/' },
            },
            autoLoad: false,
        });
        let load = function() {
            store.proxy.extraParams.prefix = prefixField.getValue() || undefined;
            store.load();
        };
        store.load();
        let sm = Ext.create('Ext.selection.RowModel', {});
        me.items = [{
            xtype: 'gridpanel',
            store: store,
            selModel: sm,
            border: false,
            columns: [
                {
                    header: gettext('Key'), dataIndex: 'key', flex: 1,
                    renderer: function(v, meta, rec) {
                        return rec.get('type') === 'prefix' ? v + ' ▸' : v;
                    },
                },
                {
                    header: gettext('Size'), dataIndex: 'size', width: 100,
                    renderer: Ext.util.Format.fileSize,
                },
                { header: gettext('Modified'), dataIndex: 'modified', width: 190 },
                { header: gettext('Storage Class'), dataIndex: 'storage', width: 120 },
            ],
            listeners: {
                itemdblclick: function(grid, rec) {
                    if (rec.get('type') === 'prefix') {
                        prefixField.setValue(rec.get('key'));
                        load();
                    }
                },
            },
            tbar: [
                prefixField,
                {
                    text: gettext('List'),
                    iconCls: 'fa fa-search',
                    handler: load,
                },
                {
                    text: gettext('Up'),
                    iconCls: 'fa fa-level-up',
                    handler: function() {
                        let p = prefixField.getValue().replace(/\/$/, '');
                        let idx = p.lastIndexOf('/');
                        prefixField.setValue(idx >= 0 ? p.slice(0, idx + 1) : '');
                        load();
                    },
                },
                {
                    text: gettext('Delete Object'),
                    iconCls: 'fa fa-trash-o',
                    disabled: true,
                    selModel: sm,
                    enableFn: function(rec) {
                        return !!rec && rec.get('type') === 'object';
                    },
                    handler: function() {
                        let rec = sm.getSelection()[0];
                        if (!rec) { return; }
                        Ext.Msg.confirm(gettext('Confirm'),
                            gettext('Delete object ') + rec.get('key') + '?',
                            function(answer) {
                                if (answer !== 'yes') { return; }
                                PVE.s3.API.request({
                                    url: '/cluster/s3/buckets/objects',
                                    method: 'DELETE',
                                    params: {
                                        bucket: me.bucket,
                                        key: rec.get('key'),
                                    },
                                    success: load,
                                });
                            });
                    },
                },
                '->',
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-refresh',
                    handler: load,
                },
            ],
        }];
        me.callParent();
    },
});

Ext.define('PVE.dc.S3BucketSettingsWindow', {
    extend: 'Ext.window.Window',
    alias: 'widget.pveDcS3BucketSettingsWindow',

    title: gettext('Bucket Settings'),
    modal: true,
    width: 520,
    layout: 'fit',

    bucket: undefined,

    initComponent: function() {
        let me = this;
        me.title = gettext('Bucket Settings') + ': ' + me.bucket;
        let form = Ext.create('Ext.form.Panel', {
            bodyPadding: 10,
            border: false,
            fieldDefaults: { labelWidth: 190, anchor: '100%' },
            items: [
                {
                    xtype: 'combobox',
                    name: 'versioning',
                    fieldLabel: gettext('Versioning'),
                    store: ['Enabled', 'Suspended'],
                    queryMode: 'local',
                    editable: false,
                    emptyText: gettext('not configured'),
                },
                {
                    xtype: 'numberfield',
                    name: 'expiration-days',
                    fieldLabel: gettext('Expire objects after (days)'),
                    minValue: 0,
                    emptyText: '0 = off',
                },
                {
                    xtype: 'numberfield',
                    name: 'noncurrent-days',
                    fieldLabel: gettext('Expire old versions after (days)'),
                    minValue: 0,
                    emptyText: '0 = off',
                },
                {
                    xtype: 'numberfield',
                    name: 'abort-days',
                    fieldLabel: gettext('Abort multipart after (days)'),
                    minValue: 0,
                    emptyText: '0 = off',
                },
            ],
            buttons: [
                {
                    text: gettext('Cancel'),
                    handler: function() { me.close(); },
                },
                {
                    text: gettext('Save'),
                    handler: function() {
                        let v = form.getValues();
                        let saves = [];
                        if (v.versioning) {
                            saves.push(new Promise(function(res) {
                                PVE.s3.API.request({
                                    url: '/cluster/s3/buckets/versioning',
                                    method: 'POST',
                                    params: {
                                        bucket: me.bucket,
                                        status: v.versioning,
                                    },
                                    success: res,
                                    failure: function() { res(); },
                                });
                            }));
                        }
                        saves.push(new Promise(function(res) {
                            PVE.s3.API.request({
                                url: '/cluster/s3/buckets/lifecycle',
                                method: 'POST',
                                params: {
                                    bucket: me.bucket,
                                    'expiration-days': v['expiration-days'] || 0,
                                    'noncurrent-days': v['noncurrent-days'] || 0,
                                    'abort-days': v['abort-days'] || 0,
                                },
                                success: res,
                                failure: function() { res(); },
                            });
                        }));
                        Promise.all(saves).then(function() { me.close(); });
                    },
                },
            ],
        });
        me.items = [form];
        me.callParent();
        PVE.s3.API.request({
            url: '/cluster/s3/buckets/settings',
            method: 'GET',
            params: { bucket: me.bucket },
            success: function(r) {
                let d = r.result.data || {};
                form.getForm().setValues({
                    versioning: d.versioning || '',
                    'expiration-days': d['expiration-days'] || '',
                    'noncurrent-days': d['noncurrent-days'] || '',
                    'abort-days': d['abort-days'] || '',
                });
            },
        });
    },
});

Ext.define('PVE.s3.API', {
    singleton: true,

    request: function(opts) {
        Proxmox.Utils.API2Request(Ext.apply({
            failure: function(r) {
                Ext.Msg.alert(gettext('Error'),
                    Proxmox.Utils.extractRequestError(r, true));
            },
        }, opts));
    },
});

Ext.define('PVE.s3.StatusView', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveS3StatusView',

    border: false,
    bodyPadding: 10,

    initComponent: function() {
        let me = this;
        me.html = gettext('loading...');
        me.callParent();
        PVE.s3.API.request({
            url: '/cluster/s3/status',
            method: 'GET',
            success: function(r) {
                let d = r.result.data || {};
                me.update(
                    '<b>' + gettext('Ceph') + ':</b> '
                    + Ext.htmlEncode(d.health || '') + '<br>'
                    + '<b>' + gettext('Realm') + ':</b> '
                    + Ext.htmlEncode(d.realm || '') + '<br>'
                    + '<b>' + gettext('Endpoint') + ':</b> '
                    + Ext.htmlEncode(d.endpoint || '') + '<br>'
                    + '<b>' + gettext('Users') + ':</b> '
                    + (d.users || 0) + '<br>'
                    + '<b>' + gettext('Buckets') + ':</b> '
                    + (d.buckets || 0));
            },
        });
    },
});

Ext.define('PVE.s3.GatewaysView', {
    extend: 'Ext.grid.GridPanel',
    alias: 'widget.pveS3GatewaysView',

    initComponent: function() {
        let me = this;
        let store = Ext.create('Ext.data.Store', {
            fields: ['gateway', 'host', 'endpoint', 'zone', 'status', 'unit'],
            proxy: { type: 'proxmox', url: '/api2/json/cluster/s3/gateways' },
            autoLoad: true,
        });
        let sm = Ext.create('Ext.selection.RowModel', {});
        Ext.apply(me, {
            store: store,
            selModel: sm,
            columns: [
                { header: gettext('Gateway'), dataIndex: 'gateway', flex: 1 },
                { header: gettext('Host'), dataIndex: 'host', width: 120 },
                { header: gettext('Endpoint'), dataIndex: 'endpoint', flex: 1 },
                { header: gettext('Zone'), dataIndex: 'zone', width: 100 },
                { header: gettext('Status'), dataIndex: 'status', width: 90 },
                { header: gettext('Unit'), dataIndex: 'unit', width: 90 },
            ],
            tbar: [
                {
                    text: gettext('Restart Gateway'),
                    iconCls: 'fa fa-refresh',
                    disabled: true,
                    handler: function() {
                        let rec = sm.getSelection()[0];
                        if (!rec) { return; }
                        Ext.Msg.confirm(gettext('Confirm'),
                            gettext('Restart gateway on ') + rec.get('host') + '?',
                            function(answer) {
                                if (answer !== 'yes') { return; }
                                PVE.s3.API.request({
                                    url: '/cluster/s3/gateways/restart',
                                    method: 'POST',
                                    params: { node: rec.get('host') },
                                    success: function() { store.load(); },
                                });
                            });
                    },
                    enableFn: function(rec) { return !!rec; },
                    selModel: sm,
                },
                '->',
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-refresh',
                    handler: function() { store.load(); },
                },
            ],
        });
        me.callParent();
    },
});

Ext.define('PVE.s3.TenantsView', {
    extend: 'Ext.grid.GridPanel',
    alias: 'widget.pveS3TenantsView',

    initComponent: function() {
        let me = this;
        let store = Ext.create('Ext.data.Store', {
            fields: ['tenant', 'pool', 'users', 'objects', 'used'],
            proxy: { type: 'proxmox', url: '/api2/json/cluster/s3/tenants' },
            autoLoad: true,
        });
        let sm = Ext.create('Ext.selection.RowModel', {});
        Ext.apply(me, {
            store: store,
            selModel: sm,
            columns: [
                { header: gettext('Tenant (Pool)'), dataIndex: 'tenant', flex: 1 },
                { header: gettext('Users'), dataIndex: 'users', width: 80 },
                { header: gettext('Objects'), dataIndex: 'objects', width: 90 },
                { header: gettext('Used'), dataIndex: 'used', width: 110,
                    renderer: Ext.util.Format.fileSize },
            ],
            tbar: [
                {
                    text: gettext('Create Tenant'),
                    iconCls: 'fa fa-plus-circle',
                    handler: function() {
                        Ext.create('PVE.dc.S3CreateTenantWindow', {
                            onDone: function() { store.load(); },
                        }).show();
                    },
                },
                {
                    text: gettext('Create User'),
                    iconCls: 'fa fa-user-plus',
                    disabled: true,
                    selModel: sm,
                    enableFn: function(rec) { return !!rec; },
                    handler: function() {
                        let rec = sm.getSelection()[0];
                        if (!rec) { return; }
                        Ext.create('PVE.dc.S3CreateUserWindow', {
                            tenantValue: rec.get('tenant'),
                        }).show();
                    },
                },
                '->',
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-refresh',
                    handler: function() { store.load(); },
                },
            ],
        });
        me.callParent();
    },
});

Ext.define('PVE.s3.UsersView', {
    extend: 'Ext.grid.GridPanel',
    alias: 'widget.pveS3UsersView',

    initComponent: function() {
        let me = this;
        let store = Ext.create('Ext.data.Store', {
            fields: ['uid', 'tenant', 'display-name', 'suspended', 'buckets',
                'objects', 'used', 'quota', 'keys'],
            proxy: { type: 'proxmox', url: '/api2/json/cluster/s3/users' },
            autoLoad: true,
        });
        let sm = Ext.create('Ext.selection.RowModel', {});
        Ext.apply(me, {
            store: store,
            selModel: sm,
            columns: [
                { header: gettext('User ID'), dataIndex: 'uid', flex: 1 },
                { header: gettext('Tenant'), dataIndex: 'tenant', width: 120 },
                { header: gettext('Display Name'), dataIndex: 'display-name', flex: 1 },
                { header: gettext('Suspended'), dataIndex: 'suspended', width: 90 },
                { header: gettext('Buckets'), dataIndex: 'buckets', width: 80 },
                { header: gettext('Objects'), dataIndex: 'objects', width: 80 },
                { header: gettext('Used'), dataIndex: 'used', width: 110,
                    renderer: Ext.util.Format.fileSize },
                { header: gettext('Keys'), dataIndex: 'keys', width: 60 },
            ],
            tbar: [
                {
                    text: gettext('Create User'),
                    iconCls: 'fa fa-plus-circle',
                    handler: function() {
                        Ext.create('PVE.dc.S3CreateUserWindow', {
                            onDone: function() { store.load(); },
                        }).show();
                    },
                },
                {
                    text: gettext('Keys'),
                    iconCls: 'fa fa-key',
                    disabled: true,
                    selModel: sm,
                    enableFn: function(rec) { return !!rec; },
                    handler: function() {
                        let rec = sm.getSelection()[0];
                        if (!rec) { return; }
                        Ext.create('PVE.dc.S3KeysWindow', {
                            uid: rec.get('uid'),
                            tenant: rec.get('tenant'),
                            listeners: {
                                destroy: function() { store.load(); },
                            },
                        }).show();
                    },
                },
                {
                    text: gettext('Suspend'),
                    iconCls: 'fa fa-pause',
                    disabled: true,
                    selModel: sm,
                    enableFn: function(rec) { return !!rec && !rec.get('suspended'); },
                    handler: function() {
                        let rec = sm.getSelection()[0];
                        if (!rec) { return; }
                        PVE.s3.API.request({
                            url: '/cluster/s3/users/suspend',
                            method: 'POST',
                            params: {
                                uid: rec.get('uid'),
                                tenant: rec.get('tenant') || undefined,
                                suspend: 1,
                            },
                            success: function() { store.load(); },
                        });
                    },
                },
                {
                    text: gettext('Enable'),
                    iconCls: 'fa fa-play',
                    disabled: true,
                    selModel: sm,
                    enableFn: function(rec) { return !!rec && !!rec.get('suspended'); },
                    handler: function() {
                        let rec = sm.getSelection()[0];
                        if (!rec) { return; }
                        PVE.s3.API.request({
                            url: '/cluster/s3/users/suspend',
                            method: 'POST',
                            params: {
                                uid: rec.get('uid'),
                                tenant: rec.get('tenant') || undefined,
                                suspend: 0,
                            },
                            success: function() { store.load(); },
                        });
                    },
                },
                {
                    text: gettext('Delete User'),
                    iconCls: 'fa fa-trash-o',
                    disabled: true,
                    selModel: sm,
                    enableFn: function(rec) { return !!rec; },
                    handler: function() {
                        let rec = sm.getSelection()[0];
                        if (!rec) { return; }
                        Ext.Msg.confirm(gettext('Confirm'),
                            gettext('Delete user ') + rec.get('uid') + '?',
                            function(answer) {
                                if (answer !== 'yes') { return; }
                                PVE.s3.API.request({
                                    url: '/cluster/s3/users',
                                    method: 'DELETE',
                                    params: {
                                        uid: rec.get('uid'),
                                        tenant: rec.get('tenant') || undefined,
                                    },
                                    success: function() { store.load(); },
                                });
                            });
                    },
                },
                '->',
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-refresh',
                    handler: function() { store.load(); },
                },
            ],
        });
        me.callParent();
    },
});

Ext.define('PVE.s3.BucketsView', {
    extend: 'Ext.grid.GridPanel',
    alias: 'widget.pveS3BucketsView',

    initComponent: function() {
        let me = this;
        let store = Ext.create('Ext.data.Store', {
            fields: ['bucket', 'owner', 'tenant', 'objects', 'used'],
            proxy: { type: 'proxmox', url: '/api2/json/cluster/s3/buckets' },
            autoLoad: true,
        });
        let sm = Ext.create('Ext.selection.RowModel', {});
        Ext.apply(me, {
            store: store,
            selModel: sm,
            columns: [
                { header: gettext('Bucket'), dataIndex: 'bucket', flex: 1 },
                { header: gettext('Owner'), dataIndex: 'owner', flex: 1 },
                { header: gettext('Tenant'), dataIndex: 'tenant', width: 120 },
                { header: gettext('Objects'), dataIndex: 'objects', width: 90 },
                { header: gettext('Used'), dataIndex: 'used', width: 110,
                    renderer: Ext.util.Format.fileSize },
            ],
            tbar: [
                {
                    text: gettext('Create Bucket'),
                    iconCls: 'fa fa-plus-circle',
                    handler: function() {
                        Ext.create('PVE.dc.S3CreateBucketWindow', {
                            onDone: function() { store.load(); },
                        }).show();
                    },
                },
                {
                    text: gettext('Objects'),
                    iconCls: 'fa fa-list',
                    disabled: true,
                    selModel: sm,
                    enableFn: function(rec) { return !!rec; },
                    handler: function() {
                        let rec = sm.getSelection()[0];
                        if (!rec) { return; }
                        Ext.create('PVE.dc.S3ObjectsWindow', {
                            bucket: rec.get('bucket'),
                        }).show();
                    },
                },
                {
                    text: gettext('Settings'),
                    iconCls: 'fa fa-cog',
                    disabled: true,
                    selModel: sm,
                    enableFn: function(rec) { return !!rec; },
                    handler: function() {
                        let rec = sm.getSelection()[0];
                        if (!rec) { return; }
                        Ext.create('PVE.dc.S3BucketSettingsWindow', {
                            bucket: rec.get('bucket'),
                        }).show();
                    },
                },
                {
                    text: gettext('Delete Bucket'),
                    iconCls: 'fa fa-trash-o',
                    disabled: true,
                    selModel: sm,
                    enableFn: function(rec) { return !!rec; },
                    handler: function() {
                        let rec = sm.getSelection()[0];
                        if (!rec) { return; }
                        Ext.Msg.confirm(gettext('Confirm'),
                            gettext('Delete bucket (and objects) ')
                                + rec.get('bucket') + '?',
                            function(answer) {
                                if (answer !== 'yes') { return; }
                                PVE.s3.API.request({
                                    url: '/cluster/s3/buckets',
                                    method: 'DELETE',
                                    params: { bucket: rec.get('bucket') },
                                    success: function() { store.load(); },
                                });
                            });
                    },
                },
                '->',
                {
                    text: gettext('Reload'),
                    iconCls: 'fa fa-refresh',
                    handler: function() { store.load(); },
                },
            ],
        });
        me.callParent();
    },
});
