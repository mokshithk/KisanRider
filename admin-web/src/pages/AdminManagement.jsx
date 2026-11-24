import React, { useState, useEffect } from 'react';
import {
  ShieldCheck,
  UserPlus,
  Mail,
  Copy,
  Check,
  RefreshCw,
  Terminal,
  Clock,
  X,
  Loader2,
} from 'lucide-react';
import { adminService } from '../services/adminService';
import DataTable from '../components/common/DataTable';
import Badge from '../components/common/Badge';

export default function AdminManagement() {
  const [admins, setAdmins] = useState([]);
  const [invitations, setInvitations] = useState([]);
  const [loading, setLoading] = useState(true);

  // Invite Modal
  const [isInviteOpen, setIsInviteOpen] = useState(false);
  const [fullName, setFullName] = useState('');
  const [email, setEmail] = useState('');
  const [inviteLoading, setInviteLoading] = useState(false);
  const [inviteError, setInviteError] = useState('');
  const [inviteResult, setInviteResult] = useState(null);
  const [copied, setCopied] = useState(false);

  // Action feedback
  const [toastMessage, setToastMessage] = useState('');

  const fetchAdmins = async () => {
    setLoading(true);
    try {
      const res = await adminService.getAdmins();
      setAdmins(res.admins || []);
      setInvitations(res.pending_invitations || []);
    } catch (err) {
      console.error('Failed to fetch admin users:', err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchAdmins();
  }, []);

  const handleInviteSubmit = async (e) => {
    e.preventDefault();
    if (!fullName.trim() || !email.trim()) {
      setInviteError('Please provide both administrator name and valid email.');
      return;
    }

    setInviteLoading(true);
    setInviteError('');
    try {
      const res = await adminService.inviteAdmin(email.trim(), fullName.trim());
      setInviteResult(res);
      fetchAdmins();
      setToastMessage(`Invitation created for ${email}.`);
      setTimeout(() => setToastMessage(''), 4000);
    } catch (err) {
      console.error('Failed to invite admin:', err);
      const detail = err.response?.data?.detail || 'Failed to generate admin invitation.';
      setInviteError(detail);
    } finally {
      setInviteLoading(false);
    }
  };

  const handleResend = async (invitationId, recipientEmail) => {
    try {
      await adminService.resendInvite(invitationId);
      setToastMessage(`Invitation renewed for ${recipientEmail}.`);
      fetchAdmins();
      setTimeout(() => setToastMessage(''), 4000);
    } catch (err) {
      console.error('Failed to resend invitation:', err);
      alert('Failed to renew invitation.');
    }
  };

  const copyToClipboard = (text) => {
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const adminColumns = [
    {
      header: 'Administrator Name',
      accessor: 'full_name',
      render: (row) => (
        <div>
          <span className="font-semibold text-text-primary block leading-tight">{row.full_name}</span>
          <span className="text-[11px] text-text-secondary mt-0.5 block">{row.email}</span>
        </div>
      ),
    },
    {
      header: 'System Role',
      render: () => (
        <span className="inline-flex items-center text-[11px] font-semibold px-2.5 py-0.5 rounded-full bg-lime-subtle text-forest border border-lime-200">
          ADMIN
        </span>
      ),
    },
    {
      header: 'Status',
      accessor: 'is_active',
      render: (row) => <Badge status={row.is_active ? 'ACTIVE' : 'SUSPENDED'} />,
    },
    {
      header: 'Created On',
      accessor: 'created_at',
      render: (row) => (row.created_at ? new Date(row.created_at).toLocaleDateString() : '-'),
    },
  ];

  const inviteColumns = [
    {
      header: 'Invited Admin',
      accessor: 'full_name',
      render: (row) => (
        <div>
          <span className="font-semibold text-text-primary block leading-tight">{row.full_name}</span>
          <span className="text-[11px] text-text-secondary mt-0.5 block">{row.email}</span>
        </div>
      ),
    },
    {
      header: 'Invitation Sent',
      accessor: 'created_at',
      render: (row) => (row.created_at ? new Date(row.created_at).toLocaleString() : '-'),
    },
    {
      header: 'Expires At',
      accessor: 'expires_at',
      render: (row) => (
        <div className="flex items-center space-x-1.5 text-xs text-amber-800">
          <Clock className="w-3.5 h-3.5 text-amber-600 shrink-0" />
          <span>{row.expires_at ? new Date(row.expires_at).toLocaleString() : '-'}</span>
        </div>
      ),
    },
    {
      header: 'Status',
      render: () => <Badge status="PENDING" text="Pending Acceptance" />,
    },
    {
      header: 'Actions',
      align: 'right',
      render: (row) => (
        <button
          onClick={() => handleResend(row.id, row.email)}
          className="text-xs text-forest hover:text-forest-light font-semibold px-3 py-1.5 rounded-lg border border-surface-border bg-white hover:bg-surface-subtle transition-colors shadow-xs"
          title="Resend invitation with fresh 24h token"
        >
          Resend Invite
        </button>
      ),
    },
  ];

  return (
    <div className="space-y-6">
      {/* Information Header & Bootstrap Instructions */}
      <div className="p-4 bg-white rounded-xl border border-surface-border text-xs text-text-secondary space-y-2 shadow-xs">
        <div className="flex items-center space-x-2 text-forest font-bold">
          <ShieldCheck className="w-4 h-4 text-forest" />
          <span className="text-text-primary text-sm font-semibold">Role-Based Administrator Governance</span>
        </div>
        <p className="leading-relaxed">
          KisanRider maintains strict equality among administrators with no artificial Super Admin
          hierarchy. Every authenticated ADMIN can invite new staff members via single-use
          cryptographic tokens. Public registration is permanently locked to FARMER and RIDER roles.
        </p>
      </div>

      {toastMessage && (
        <div className="p-3.5 rounded-xl bg-emerald-50 border border-emerald-200/80 text-xs font-semibold text-emerald-900 animate-in fade-in">
          {toastMessage}
        </div>
      )}

      {/* Action Bar */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div>
          <h3 className="text-base font-bold text-text-primary tracking-tight">Active Administrators</h3>
          <p className="text-xs text-text-secondary">Personnel with full platform management authorization</p>
        </div>
        <button
          onClick={() => {
            setIsInviteOpen(true);
            setFullName('');
            setEmail('');
            setInviteError('');
            setInviteResult(null);
          }}
          className="inline-flex items-center space-x-2 px-4 py-2 rounded-lg text-xs font-semibold bg-forest text-white hover:bg-forest-light transition-colors shadow-xs self-start sm:self-auto"
        >
          <UserPlus className="w-3.5 h-3.5 text-lime-accent" />
          <span>Invite New Administrator</span>
        </button>
      </div>

      {/* Active Admins Table */}
      <DataTable
        columns={adminColumns}
        data={admins}
        total={admins.length}
        page={1}
        limit={admins.length}
        totalPages={1}
        isLoading={loading}
        emptyMessage="No administrators configured."
      />

      {/* Pending Invitations Section */}
      <div className="pt-4 border-t border-surface-border space-y-3">
        <div>
          <h3 className="text-base font-bold text-text-primary tracking-tight">Pending Invitations</h3>
          <p className="text-xs text-text-secondary">
            Unaccepted single-use invitation tokens valid for 24 hours
          </p>
        </div>
        <DataTable
          columns={inviteColumns}
          data={invitations}
          total={invitations.length}
          page={1}
          limit={invitations.length}
          totalPages={1}
          isLoading={loading}
          emptyMessage="No pending invitations. All invited administrators have accepted their tokens."
        />
      </div>

      {/* Bootstrap CLI Instructions Card */}
      <div className="p-4 bg-surface-subtle/80 rounded-xl border border-surface-border text-xs space-y-2 shadow-xs">
        <div className="flex items-center space-x-2 font-bold text-text-primary">
          <Terminal className="w-4 h-4 text-forest" />
          <span>Initial System Provisioning Command</span>
        </div>
        <p className="text-text-secondary">
          To safely initialize the first administrative account in a brand new deployment:
        </p>
        <div className="bg-forest-dark p-3 rounded-lg text-emerald-300 font-mono text-[11px] overflow-x-auto">
          python bootstrap_admin.py
        </div>
      </div>

      {/* Invite Modal */}
      {isInviteOpen && (
        <div className="fixed inset-0 z-50 overflow-y-auto bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4">
          <div className="bg-white rounded-xl max-w-lg w-full border border-surface-border shadow-modal overflow-hidden transition-all animate-in fade-in zoom-in-95 duration-150">
            <div className="flex items-center justify-between px-6 py-4 border-b border-surface-border bg-surface-subtle/50">
              <h3 className="text-base font-bold text-text-primary tracking-tight">Invite Administrator</h3>
              <button
                onClick={() => setIsInviteOpen(false)}
                disabled={inviteLoading}
                className="text-text-secondary hover:text-text-primary p-1.5 rounded-lg hover:bg-surface-subtle transition-colors"
                aria-label="Close modal"
              >
                <X className="w-4 h-4" />
              </button>
            </div>

            {inviteResult ? (
              <div className="p-6 space-y-4">
                <div className="p-4 bg-emerald-50 rounded-xl border border-emerald-200/80 text-xs text-emerald-950 space-y-2">
                  <div className="font-bold flex items-center space-x-1.5 text-emerald-900">
                    <Check className="w-4 h-4 text-emerald-600" />
                    <span>Invitation Successfully Generated!</span>
                  </div>
                  <p>
                    A single-use onboarding URL has been issued. If SMTP email delivery is configured, an
                    invitation message has also been dispatched to <strong>{inviteResult.invitation.email}</strong>.
                  </p>
                </div>

                <div>
                  <label className="block text-xs font-semibold text-text-primary mb-1">
                    Direct Onboarding Link (Valid 24 hours):
                  </label>
                  <div className="flex items-center space-x-2">
                    <input
                      type="text"
                      readOnly
                      value={inviteResult.invite_link}
                      className="flex-1 text-xs font-mono bg-surface-subtle border border-surface-border rounded-lg px-3 py-2 text-text-primary"
                    />
                    <button
                      type="button"
                      onClick={() => copyToClipboard(inviteResult.invite_link)}
                      className="px-3.5 py-2 text-xs font-semibold rounded-lg bg-forest text-white hover:bg-forest-light transition-colors flex items-center space-x-1 shrink-0"
                    >
                      {copied ? <Check className="w-3.5 h-3.5" /> : <Copy className="w-3.5 h-3.5" />}
                      <span>{copied ? 'Copied' : 'Copy Link'}</span>
                    </button>
                  </div>
                </div>

                <div className="pt-2 flex justify-end">
                  <button
                    onClick={() => {
                      setIsInviteOpen(false);
                      setInviteResult(null);
                    }}
                    className="px-4 py-2 text-xs font-semibold rounded-lg bg-forest text-white hover:bg-forest-light transition-colors"
                  >
                    Done
                  </button>
                </div>
              </div>
            ) : (
              <form onSubmit={handleInviteSubmit} className="p-6 space-y-4">
                <div>
                  <label className="block text-xs font-semibold text-text-primary mb-1.5">
                    Full Name <span className="text-rose-600">*</span>
                  </label>
                  <input
                    type="text"
                    value={fullName}
                    onChange={(e) => setFullName(e.target.value)}
                    placeholder="e.g. Ramesh Hegde"
                    disabled={inviteLoading}
                    className="w-full text-xs rounded-lg border border-surface-border px-3.5 py-2.5 bg-white text-text-primary focus:outline-none focus:ring-2 focus:ring-forest/20 focus:border-forest transition-all"
                  />
                </div>

                <div>
                  <label className="block text-xs font-semibold text-text-primary mb-1.5">
                    Official Email Address <span className="text-rose-600">*</span>
                  </label>
                  <input
                    type="email"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    placeholder="operations@kisanrider.in"
                    disabled={inviteLoading}
                    className="w-full text-xs rounded-lg border border-surface-border px-3.5 py-2.5 bg-white text-text-primary focus:outline-none focus:ring-2 focus:ring-forest/20 focus:border-forest transition-all"
                  />
                  <p className="text-[11px] text-text-secondary mt-1">
                    An email with an activation link will be dispatched.
                  </p>
                </div>

                {inviteError && (
                  <p className="text-xs text-rose-600 font-medium">{inviteError}</p>
                )}

                <div className="pt-2 border-t border-surface-border flex items-center justify-end space-x-3">
                  <button
                    type="button"
                    onClick={() => setIsInviteOpen(false)}
                    disabled={inviteLoading}
                    className="px-4 py-2 text-xs font-medium rounded-lg border border-surface-border bg-white text-text-primary hover:bg-surface-subtle transition-colors disabled:opacity-50"
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    disabled={inviteLoading}
                    className="inline-flex items-center space-x-2 px-4 py-2 text-xs font-semibold rounded-lg bg-forest text-white hover:bg-forest-light transition-all shadow-xs disabled:opacity-50"
                  >
                    {inviteLoading && <Loader2 className="w-3.5 h-3.5 animate-spin" />}
                    <span>Issue Invitation</span>
                  </button>
                </div>
              </form>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
