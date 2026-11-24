import React, { useState, useEffect } from 'react';
import {
  Eye,
  CheckCircle,
  RefreshCw,
  AlertCircle,
  Loader2,
  X,
} from 'lucide-react';
import { adminService } from '../services/adminService';
import DataTable from '../components/common/DataTable';
import Badge from '../components/common/Badge';
import DetailModal from '../components/common/DetailModal';

export default function Settlements() {
  const [settlements, setSettlements] = useState([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [loading, setLoading] = useState(true);

  // Filters
  const [statusFilter, setStatusFilter] = useState('ALL');

  // Detail Modal
  const [selectedSettlement, setSelectedSettlement] = useState(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [isDetailOpen, setIsDetailOpen] = useState(false);

  // Reconciliation Modal
  const [reconcileModal, setReconcileModal] = useState({
    isOpen: false,
    settlement: null,
  });
  const [paymentRef, setPaymentRef] = useState('');
  const [reconcileNotes, setReconcileNotes] = useState('');
  const [reconcileError, setReconcileError] = useState('');
  const [reconcileLoading, setReconcileLoading] = useState(false);
  const [toastMessage, setToastMessage] = useState('');

  const fetchSettlements = async (currentPage = page) => {
    setLoading(true);
    try {
      const params = {
        page: currentPage,
        limit: 10,
        status_filter: statusFilter,
      };

      const res = await adminService.getSettlements(params);
      setSettlements(res.items || []);
      setTotal(res.total || 0);
      setPage(res.page || 1);
      setTotalPages(res.total_pages || 1);
    } catch (err) {
      console.error('Failed to fetch settlements:', err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchSettlements(1);
  }, [statusFilter]);

  const openDetail = async (s) => {
    setIsDetailOpen(true);
    setDetailLoading(true);
    try {
      const data = await adminService.getSettlementDetail(s.id);
      setSelectedSettlement(data);
    } catch (err) {
      console.error('Failed to load settlement detail:', err);
    } finally {
      setDetailLoading(false);
    }
  };

  const handleReconcileSubmit = async (e) => {
    e.preventDefault();
    if (!paymentRef.trim()) {
      setReconcileError('External payment reference / UTR number is required.');
      return;
    }

    setReconcileLoading(true);
    setReconcileError('');
    try {
      await adminService.reconcileSettlement(
        reconcileModal.settlement.id,
        paymentRef.trim(),
        reconcileNotes.trim()
      );
      setToastMessage(
        `Settlement #${reconcileModal.settlement.id.slice(0, 8)} reconciled to PAID.`
      );
      setReconcileModal({ isOpen: false, settlement: null });
      setPaymentRef('');
      setReconcileNotes('');
      fetchSettlements(page);
      setTimeout(() => setToastMessage(''), 4000);
    } catch (err) {
      console.error('Failed to reconcile settlement:', err);
      const detail = err.response?.data?.detail || 'Reconciliation failed.';
      setReconcileError(detail);
    } finally {
      setReconcileLoading(false);
    }
  };

  const columns = [
    {
      header: 'Settlement ID',
      accessor: 'id',
      render: (row) => (
        <span className="font-mono text-xs font-semibold text-text-primary">
          #{row.id.slice(0, 8)}
        </span>
      ),
    },
    {
      header: 'Farmer (Produce)',
      accessor: 'farmer_name',
      render: (row) => (
        <div>
          <span className="font-semibold text-text-primary block leading-tight">{row.farmer_name}</span>
          <span className="text-[11px] text-text-secondary mt-0.5 block">
            {row.crop_name} ({row.quantity_kg || 0} kg)
          </span>
        </div>
      ),
    },
    {
      header: 'Rider Payee',
      accessor: 'rider_name',
      render: (row) => (
        <span className="font-medium text-text-primary text-xs">{row.rider_name || '-'}</span>
      ),
    },
    {
      header: 'Gross Amount',
      accessor: 'gross_amount',
      render: (row) => (
        <span className="text-xs font-semibold text-text-primary">
          ₹{(row.gross_amount || 0).toLocaleString('en-IN', { maximumFractionDigits: 2 })}
        </span>
      ),
    },
    {
      header: 'Platform Fee (2%)',
      accessor: 'platform_fee',
      render: (row) => (
        <span className="text-xs text-text-secondary">
          ₹{(row.platform_fee || 0).toLocaleString('en-IN', { maximumFractionDigits: 2 })}
        </span>
      ),
    },
    {
      header: 'Net Payout',
      accessor: 'net_payout',
      render: (row) => (
        <span className="text-xs font-bold text-forest">
          ₹{(row.net_payout || row.total_payout || 0).toLocaleString('en-IN', { maximumFractionDigits: 2 })}
        </span>
      ),
    },
    {
      header: 'Payment Status',
      accessor: 'status',
      render: (row) => <Badge status={row.status} />,
    },
    {
      header: 'Date',
      accessor: 'created_at',
      render: (row) =>
        row.created_at ? new Date(row.created_at).toLocaleDateString() : '-',
    },
    {
      header: 'Actions',
      align: 'right',
      render: (row) => (
        <div className="flex items-center justify-end space-x-1.5">
          <button
            onClick={() => openDetail(row)}
            className="p-1.5 rounded-lg text-text-secondary hover:text-forest hover:bg-surface-subtle transition-colors"
            title="Inspect Settlement"
            aria-label="Inspect Settlement"
          >
            <Eye className="w-4 h-4" />
          </button>
          {row.status === 'PENDING' && (
            <button
              onClick={() => {
                setReconcileModal({ isOpen: true, settlement: row });
                setPaymentRef('');
                setReconcileNotes('');
                setReconcileError('');
              }}
              className="p-1.5 rounded-lg text-emerald-700 hover:bg-emerald-50 transition-colors"
              title="Manual Reconciliation (Reconcile to PAID)"
              aria-label="Manual Reconciliation"
            >
              <CheckCircle className="w-4 h-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-5">
      {/* Information Header */}
      <div className="p-4 bg-white rounded-xl border border-surface-border text-xs text-text-secondary flex items-start space-x-3 shadow-xs">
        <AlertCircle className="w-4 h-4 text-forest shrink-0 mt-0.5" />
        <p className="leading-relaxed">
          <strong className="text-text-primary font-semibold">Financial Protocol:</strong> Real calculations
          based on base fare, distance rate (₹15/km), and crate load weight. Manual reconciliation
          requires an external bank transaction reference (UTR) and never claims automated funds
          transfer. All changes logged to audit trail.
        </p>
      </div>

      {toastMessage && (
        <div className="p-3.5 rounded-xl bg-emerald-50 border border-emerald-200/80 text-xs font-semibold text-emerald-900 animate-in fade-in">
          {toastMessage}
        </div>
      )}

      {/* Filter Bar */}
      <div className="bg-white p-4 rounded-xl border border-surface-border flex flex-col md:flex-row md:items-center justify-between gap-3 shadow-xs">
        <div className="flex items-center space-x-3">
          <select
            value={statusFilter}
            onChange={(e) => setStatusFilter(e.target.value)}
            className="text-xs rounded-lg border border-surface-border px-3 py-2 bg-white text-text-primary focus:outline-none focus:ring-2 focus:ring-forest/20 focus:border-forest transition-all"
          >
            <option value="ALL">All Settlement Statuses</option>
            <option value="PENDING">Pending Reconciliation</option>
            <option value="PAID">Paid / Reconciled</option>
          </select>
        </div>

        <button
          onClick={() => fetchSettlements(page)}
          className="p-2 rounded-lg border border-surface-border text-text-secondary hover:text-text-primary hover:bg-surface-subtle transition-colors shadow-xs self-start md:self-auto"
          title="Refresh list"
          aria-label="Refresh list"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${loading ? 'animate-spin text-forest' : ''}`} />
        </button>
      </div>

      {/* Settlements Table */}
      <DataTable
        columns={columns}
        data={settlements}
        total={total}
        page={page}
        limit={10}
        totalPages={totalPages}
        onPageChange={(p) => fetchSettlements(p)}
        isLoading={loading}
        emptyMessage="No settlement records match criteria."
      />

      {/* Reconcile Modal */}
      {reconcileModal.isOpen && (
        <div className="fixed inset-0 z-50 overflow-y-auto bg-slate-900/60 backdrop-blur-xs flex items-center justify-center p-4">
          <div className="bg-white rounded-xl max-w-lg w-full border border-surface-border shadow-modal overflow-hidden transition-all animate-in fade-in zoom-in-95 duration-150">
            <div className="flex items-center justify-between px-6 py-4 border-b border-surface-border bg-surface-subtle/50">
              <h3 className="text-base font-bold text-text-primary tracking-tight">Manual Reconciliation</h3>
              <button
                onClick={() => setReconcileModal({ isOpen: false, settlement: null })}
                disabled={reconcileLoading}
                className="text-text-secondary hover:text-text-primary p-1.5 rounded-lg hover:bg-surface-subtle transition-colors"
                aria-label="Close modal"
              >
                <X className="w-4 h-4" />
              </button>
            </div>

            <form onSubmit={handleReconcileSubmit} className="p-6 space-y-4">
              <div className="bg-surface-subtle/70 p-3.5 rounded-lg border border-surface-border text-xs space-y-1">
                <span className="text-text-secondary font-medium">Settlement Target:</span>
                <p className="font-semibold text-text-primary">
                  #{reconcileModal.settlement?.id?.slice(0, 8)} • Payee: {reconcileModal.settlement?.rider_name || 'Driver'}
                </p>
                <p className="font-bold text-forest">
                  Net Amount: ₹{(reconcileModal.settlement?.net_payout || reconcileModal.settlement?.total_payout || 0).toLocaleString('en-IN')}
                </p>
              </div>

              <div>
                <label className="block text-xs font-semibold text-text-primary mb-1.5">
                  Bank Reference / UTR Number <span className="text-rose-600">*</span>
                </label>
                <input
                  type="text"
                  value={paymentRef}
                  onChange={(e) => {
                    setPaymentRef(e.target.value);
                    if (reconcileError) setReconcileError('');
                  }}
                  placeholder="e.g. UTR1234567890 / IMPS / NEFT Ref"
                  disabled={reconcileLoading}
                  className="w-full text-xs rounded-lg border border-surface-border px-3.5 py-2.5 bg-white text-text-primary focus:outline-none focus:ring-2 focus:ring-forest/20 focus:border-forest transition-all"
                />
                {reconcileError && (
                  <p className="text-xs text-rose-600 mt-1.5 font-medium">{reconcileError}</p>
                )}
              </div>

              <div>
                <label className="block text-xs font-semibold text-text-primary mb-1.5">
                  Internal Audit Notes (Optional)
                </label>
                <textarea
                  value={reconcileNotes}
                  onChange={(e) => setReconcileNotes(e.target.value)}
                  placeholder="Bank transfer verification notes..."
                  disabled={reconcileLoading}
                  rows={2}
                  className="w-full text-xs rounded-lg border border-surface-border px-3.5 py-2.5 bg-white text-text-primary focus:outline-none focus:ring-2 focus:ring-forest/20 focus:border-forest transition-all"
                />
              </div>

              <div className="pt-2 border-t border-surface-border flex items-center justify-end space-x-3">
                <button
                  type="button"
                  onClick={() => setReconcileModal({ isOpen: false, settlement: null })}
                  disabled={reconcileLoading}
                  className="px-4 py-2 text-xs font-medium rounded-lg border border-surface-border bg-white text-text-primary hover:bg-surface-subtle transition-colors disabled:opacity-50"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={reconcileLoading}
                  className="inline-flex items-center space-x-2 px-4 py-2 text-xs font-semibold rounded-lg bg-forest text-white hover:bg-forest-light transition-all shadow-xs disabled:opacity-50"
                >
                  {reconcileLoading && <Loader2 className="w-3.5 h-3.5 animate-spin" />}
                  <span>Mark as Reconciled (PAID)</span>
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Detail Modal */}
      <DetailModal
        isOpen={isDetailOpen}
        onClose={() => setIsDetailOpen(false)}
        title={
          selectedSettlement
            ? `Settlement #${selectedSettlement.settlement.id.slice(0, 8)} Details`
            : 'Settlement'
        }
        subtitle={`Audit breakdown • Payee: ${selectedSettlement?.rider?.full_name || 'Driver'}`}
        maxWidth="max-w-3xl"
      >
        {detailLoading ? (
          <div className="py-12 text-center text-text-secondary text-xs">Loading ledger details...</div>
        ) : selectedSettlement ? (
          <div className="space-y-6">
            {/* Top Stat Overview */}
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 bg-surface-subtle/70 p-4 rounded-xl border border-surface-border text-xs">
              <div>
                <span className="text-text-secondary block font-medium">Status</span>
                <div className="mt-1">
                  <Badge status={selectedSettlement.settlement.status} />
                </div>
              </div>
              <div>
                <span className="text-text-secondary block font-medium">Gross Fare</span>
                <span className="font-semibold text-text-primary block mt-1">
                  ₹{selectedSettlement.settlement.gross_amount}
                </span>
              </div>
              <div>
                <span className="text-text-secondary block font-medium">Platform Fee</span>
                <span className="font-semibold text-text-primary block mt-1">
                  ₹{selectedSettlement.settlement.platform_fee}
                </span>
              </div>
              <div>
                <span className="text-text-secondary block font-medium">Net Payout</span>
                <span className="font-bold text-forest block mt-1">
                  ₹{selectedSettlement.settlement.net_payout || selectedSettlement.settlement.total_payout}
                </span>
              </div>
            </div>

            {/* Reconciliation Audit Info */}
            <div className="p-4 bg-white rounded-xl border border-surface-border space-y-2.5 text-xs">
              <h4 className="font-bold uppercase tracking-wider text-text-secondary text-[11px]">Bank Reconcile Audit</h4>
              <p>
                <strong className="text-text-primary font-semibold">Payment Reference (UTR):</strong>{' '}
                <span className="font-mono">{selectedSettlement.settlement.payment_reference || 'Pending settlement transfer'}</span>
              </p>
              {selectedSettlement.settlement.reconciled_by && (
                <p>
                  <strong className="text-text-primary font-semibold">Reconciled By Admin:</strong>{' '}
                  {selectedSettlement.settlement.reconciled_by}
                </p>
              )}
              {selectedSettlement.settlement.notes && (
                <p>
                  <strong className="text-text-primary font-semibold">Notes:</strong> {selectedSettlement.settlement.notes}
                </p>
              )}
            </div>

            {/* Bank Credentials */}
            {selectedSettlement.rider && (
              <div className="p-4 bg-surface-subtle/70 rounded-xl border border-surface-border space-y-2 text-xs">
                <h4 className="font-bold uppercase tracking-wider text-text-secondary text-[11px]">Payee Bank Account</h4>
                <div className="grid grid-cols-2 gap-2 mt-1">
                  <div>
                    <span className="text-text-secondary">Bank:</span>{' '}
                    <span className="font-medium text-text-primary">{selectedSettlement.rider.bank_name || '-'}</span>
                  </div>
                  <div>
                    <span className="text-text-secondary">Account:</span>{' '}
                    <span className="font-medium text-text-primary">{selectedSettlement.rider.account_number || '-'}</span>
                  </div>
                  <div>
                    <span className="text-text-secondary">IFSC:</span>{' '}
                    <span className="font-medium text-text-primary">{selectedSettlement.rider.ifsc_code || '-'}</span>
                  </div>
                  <div>
                    <span className="text-text-secondary">UPI:</span>{' '}
                    <span className="font-medium text-text-primary">{selectedSettlement.rider.upi_id || '-'}</span>
                  </div>
                </div>
              </div>
            )}
          </div>
        ) : null}
      </DetailModal>
    </div>
  );
}
