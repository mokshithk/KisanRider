import React, { useState, useEffect } from 'react';
import {
  Search,
  Eye,
  UserX,
  UserCheck,
  RefreshCw,
  Truck,
  CreditCard,
  AlertCircle,
  Navigation,
} from 'lucide-react';
import { adminService } from '../services/adminService';
import DataTable from '../components/common/DataTable';
import Badge from '../components/common/Badge';
import ConfirmationModal from '../components/common/ConfirmationModal';
import DetailModal from '../components/common/DetailModal';

export default function Riders() {
  const [riders, setRiders] = useState([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [loading, setLoading] = useState(true);

  // Filters
  const [searchTerm, setSearchTerm] = useState('');
  const [dutyStatus, setDutyStatus] = useState('ALL');
  const [statusFilter, setStatusFilter] = useState('ALL');

  // Detail Modal
  const [selectedRider, setSelectedRider] = useState(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [isDetailOpen, setIsDetailOpen] = useState(false);

  // Consequential Action Modal
  const [confirmModal, setConfirmModal] = useState({
    isOpen: false,
    rider: null,
    targetActive: false,
  });
  const [actionLoading, setActionLoading] = useState(false);
  const [toastMessage, setToastMessage] = useState('');

  const fetchRiders = async (currentPage = page) => {
    setLoading(true);
    try {
      const params = {
        page: currentPage,
        limit: 10,
        duty_status: dutyStatus,
        status_filter: statusFilter,
      };
      if (searchTerm.trim()) params.search = searchTerm.trim();

      const res = await adminService.getRiders(params);
      setRiders(res.items || []);
      setTotal(res.total || 0);
      setPage(res.page || 1);
      setTotalPages(res.total_pages || 1);
    } catch (err) {
      console.error('Failed to fetch riders:', err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchRiders(1);
  }, [dutyStatus, statusFilter]);

  const handleSearchSubmit = (e) => {
    e.preventDefault();
    fetchRiders(1);
  };

  const openDetail = async (rider) => {
    setIsDetailOpen(true);
    setDetailLoading(true);
    try {
      const data = await adminService.getRiderDetail(rider.id);
      setSelectedRider(data);
    } catch (err) {
      console.error('Failed to load rider detail:', err);
    } finally {
      setDetailLoading(false);
    }
  };

  const handleStatusChangeConfirm = async (reason) => {
    const { rider, targetActive } = confirmModal;
    if (!rider) return;

    setActionLoading(true);
    try {
      await adminService.updateRiderStatus(rider.id, targetActive, reason);
      setToastMessage(
        `Rider ${rider.full_name} has been ${targetActive ? 'reactivated' : 'suspended'}.`
      );
      setConfirmModal({ isOpen: false, rider: null, targetActive: false });
      fetchRiders(page);
      setTimeout(() => setToastMessage(''), 4000);
    } catch (err) {
      console.error('Failed to update status:', err);
      alert('Failed to update account status. Please check backend logs.');
    } finally {
      setActionLoading(false);
    }
  };

  const columns = [
    {
      header: 'Rider Name',
      accessor: 'full_name',
      render: (row) => (
        <div>
          <span className="font-semibold text-text-primary block">{row.full_name}</span>
          <span className="text-xs text-text-secondary">{row.email}</span>
        </div>
      ),
    },
    {
      header: 'Phone Number',
      accessor: 'phone_number',
      render: (row) => row.phone_number || row.phone || '-',
    },
    {
      header: 'Vehicle Type',
      accessor: 'vehicle_type',
      render: (row) => (
        <div>
          <span className="block font-medium text-text-primary">{row.vehicle_type || 'Transport'}</span>
          <span className="text-[11px] text-text-secondary">{row.vehicle_number || 'No plate'}</span>
        </div>
      ),
    },
    {
      header: 'Capacity',
      accessor: 'payload_capacity_kg',
      render: (row) => (row.payload_capacity_kg ? `${row.payload_capacity_kg} kg` : '-'),
    },
    {
      header: 'Operating Routes',
      accessor: 'operating_routes',
      render: (row) => (
        <span className="truncate max-w-[150px] block" title={row.operating_routes}>
          {row.operating_routes || 'All Districts'}
        </span>
      ),
    },
    {
      header: 'Duty',
      accessor: 'is_on_duty',
      render: (row) => (
        <Badge
          status={row.is_on_duty ? 'ON_DUTY' : 'OFF_DUTY'}
          text={row.is_on_duty ? 'On Duty' : 'Off Duty'}
        />
      ),
    },
    {
      header: 'Status',
      accessor: 'is_active',
      render: (row) => <Badge status={row.is_active ? 'ACTIVE' : 'SUSPENDED'} />,
    },
    {
      header: 'Actions',
      align: 'right',
      render: (row) => (
        <div className="flex items-center justify-end space-x-1.5">
          <button
            onClick={() => openDetail(row)}
            className="p-1 rounded text-text-secondary hover:text-forest hover:bg-surface-subtle transition-colors"
            title="View Details"
          >
            <Eye className="w-4 h-4" />
          </button>
          {row.is_active ? (
            <button
              onClick={() =>
                setConfirmModal({
                  isOpen: true,
                  rider: row,
                  targetActive: false,
                })
              }
              className="p-1 rounded text-rose-600 hover:bg-rose-50 transition-colors"
              title="Suspend Rider Account"
            >
              <UserX className="w-4 h-4" />
            </button>
          ) : (
            <button
              onClick={() =>
                setConfirmModal({
                  isOpen: true,
                  rider: row,
                  targetActive: true,
                })
              }
              className="p-1 rounded text-emerald-700 hover:bg-emerald-50 transition-colors"
              title="Reactivate Rider Account"
            >
              <UserCheck className="w-4 h-4" />
            </button>
          )}
        </div>
      ),
    },
  ];

  return (
    <div className="space-y-5">
      {/* Information Banner */}
      <div className="p-3.5 bg-white rounded-lg border border-surface-border text-xs text-text-secondary flex items-start space-x-2.5 shadow-xs">
        <AlertCircle className="w-4 h-4 text-forest shrink-0 mt-0.5" />
        <p className="leading-relaxed">
          <strong className="text-text-primary">Policy Note:</strong> Rider registration is
          automatic based on driver mobile credentials and password authentication. No manual Admin
          approval. Administrative suspension locks active routing and trip dispatches immediately.
        </p>
      </div>

      {toastMessage && (
        <div className="p-3 rounded-lg bg-emerald-50 border border-emerald-200 text-xs font-semibold text-emerald-900 animate-in fade-in">
          {toastMessage}
        </div>
      )}

      {/* Filter and Search Bar */}
      <div className="bg-white p-4 rounded-lg border border-surface-border flex flex-col md:flex-row md:items-center justify-between gap-3 shadow-xs">
        <form onSubmit={handleSearchSubmit} className="flex-1 flex items-center space-x-2">
          <div className="relative flex-1 max-w-md">
            <Search className="w-4 h-4 absolute left-3 top-2.5 text-text-secondary" />
            <input
              type="text"
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              placeholder="Search by rider name, license number, vehicle plate..."
              className="w-full text-xs rounded border border-surface-border pl-9 pr-3 py-2 focus:outline-none focus:ring-1 focus:ring-forest text-text-primary"
            />
          </div>
          <button
            type="submit"
            className="px-3.5 py-2 text-xs font-medium rounded bg-forest text-white hover:bg-forest-light transition-colors"
          >
            Search
          </button>
        </form>

        <div className="flex items-center space-x-3">
          {/* Duty status filter */}
          <select
            value={dutyStatus}
            onChange={(e) => setDutyStatus(e.target.value)}
            className="text-xs rounded border border-surface-border px-3 py-2 bg-white text-text-primary focus:outline-none focus:ring-1 focus:ring-forest"
          >
            <option value="ALL">All Duty Statuses</option>
            <option value="ON_DUTY">On Duty</option>
            <option value="OFF_DUTY">Off Duty</option>
          </select>

          {/* Account status filter */}
          <select
            value={statusFilter}
            onChange={(e) => setStatusFilter(e.target.value)}
            className="text-xs rounded border border-surface-border px-3 py-2 bg-white text-text-primary focus:outline-none focus:ring-1 focus:ring-forest"
          >
            <option value="ALL">All Account Statuses</option>
            <option value="ACTIVE">Active Accounts</option>
            <option value="SUSPENDED">Suspended Accounts</option>
          </select>

          <button
            onClick={() => fetchRiders(page)}
            className="p-2 rounded border border-surface-border text-text-secondary hover:text-text-primary hover:bg-surface-subtle transition-colors"
            title="Refresh list"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${loading ? 'animate-spin' : ''}`} />
          </button>
        </div>
      </div>

      {/* Riders Table */}
      <DataTable
        columns={columns}
        data={riders}
        total={total}
        page={page}
        limit={10}
        totalPages={totalPages}
        onPageChange={(p) => fetchRiders(p)}
        isLoading={loading}
        emptyMessage="No driver or transport vehicle records found."
      />

      {/* Confirmation Modal */}
      <ConfirmationModal
        isOpen={confirmModal.isOpen}
        onClose={() => setConfirmModal({ isOpen: false, rider: null, targetActive: false })}
        onConfirm={handleStatusChangeConfirm}
        title={confirmModal.targetActive ? 'Reactivate Rider Account' : 'Suspend Rider Account'}
        actionType={confirmModal.targetActive ? 'primary' : 'danger'}
        affectedRecord={
          confirmModal.rider
            ? `${confirmModal.rider.full_name} (${confirmModal.rider.vehicle_number || confirmModal.rider.email})`
            : ''
        }
        consequences={
          confirmModal.targetActive
            ? 'The rider will immediately be able to toggle on-duty status and accept farm dispatches.'
            : 'The rider will be blocked from receiving transport orders, accessing the driver portal, or accepting trips.'
        }
        requireReason={true}
        reasonPlaceholder="Specify administrative reason for this rider status modification..."
        confirmText={confirmModal.targetActive ? 'Confirm Reactivation' : 'Confirm Suspension'}
        isLoading={actionLoading}
      />

      {/* Detail Modal */}
      <DetailModal
        isOpen={isDetailOpen}
        onClose={() => setIsDetailOpen(false)}
        title={selectedRider?.rider.full_name || 'Rider Details'}
        subtitle={`Driver profile • Vehicle: ${selectedRider?.rider.vehicle_number || 'N/A'}`}
        maxWidth="max-w-3xl"
      >
        {detailLoading ? (
          <div className="py-12 text-center text-text-secondary text-xs">Loading driver profile...</div>
        ) : selectedRider ? (
          <div className="space-y-6">
            {/* Highlights Grid */}
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 bg-surface-subtle p-3.5 rounded-lg border border-surface-border text-xs">
              <div>
                <span className="text-text-secondary block">Duty Status</span>
                <Badge
                  status={selectedRider.rider.is_on_duty ? 'ON_DUTY' : 'OFF_DUTY'}
                  text={selectedRider.rider.is_on_duty ? 'On Duty' : 'Off Duty'}
                />
              </div>
              <div>
                <span className="text-text-secondary block">Vehicle Capacity</span>
                <span className="font-semibold text-text-primary block mt-0.5">
                  {selectedRider.rider.payload_capacity_kg ? `${selectedRider.rider.payload_capacity_kg} kg` : '-'}
                </span>
              </div>
              <div>
                <span className="text-text-secondary block">Driver Licence</span>
                <span className="font-semibold text-text-primary block mt-0.5">
                  {selectedRider.rider.license_number || '-'}
                </span>
              </div>
              <div>
                <span className="text-text-secondary block">Account Status</span>
                <Badge status={selectedRider.rider.is_active ? 'ACTIVE' : 'SUSPENDED'} />
              </div>
            </div>

            {/* Vehicle & Bank Specs */}
            <div>
              <h4 className="text-xs font-bold uppercase tracking-wider text-text-secondary mb-2">
                Vehicle & Settlement Information
              </h4>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 text-xs bg-white p-3.5 rounded border border-surface-border">
                <div>
                  <span className="text-text-secondary">Vehicle Model / Type:</span>{' '}
                  <span className="font-medium text-text-primary">{selectedRider.rider.vehicle_type || '-'}</span>
                </div>
                <div>
                  <span className="text-text-secondary">Vehicle Plate:</span>{' '}
                  <span className="font-medium text-text-primary">{selectedRider.rider.vehicle_number || '-'}</span>
                </div>
                <div>
                  <span className="text-text-secondary">Operating Corridor:</span>{' '}
                  <span className="font-medium text-text-primary">{selectedRider.rider.operating_routes || '-'}</span>
                </div>
                <div>
                  <span className="text-text-secondary">Bank / Account:</span>{' '}
                  <span className="font-medium text-text-primary">
                    {selectedRider.rider.bank_name ? `${selectedRider.rider.bank_name} (${selectedRider.rider.account_number || ''})` : '-'}
                  </span>
                </div>
                <div>
                  <span className="text-text-secondary">IFSC Code:</span>{' '}
                  <span className="font-medium text-text-primary">{selectedRider.rider.ifsc_code || '-'}</span>
                </div>
                <div>
                  <span className="text-text-secondary">UPI ID:</span>{' '}
                  <span className="font-medium text-text-primary">{selectedRider.rider.upi_id || '-'}</span>
                </div>
              </div>
            </div>

            {/* Recent Trips History */}
            <div>
              <h4 className="text-xs font-bold uppercase tracking-wider text-text-secondary mb-2">
                Recent Trips Completed ({selectedRider.trips?.length || 0})
              </h4>
              <div className="space-y-2">
                {selectedRider.trips?.length > 0 ? (
                  selectedRider.trips.slice(0, 5).map((t) => (
                    <div key={t.id} className="p-2.5 rounded bg-surface-bg border border-surface-border text-xs flex justify-between items-center">
                      <div>
                        <span className="font-semibold text-text-primary block">Trip #{t.id.slice(0, 8)}</span>
                        <span className="text-text-secondary text-[11px] block mt-0.5">{t.pickup_address || 'Origin'}</span>
                      </div>
                      <Badge status={t.status} />
                    </div>
                  ))
                ) : (
                  <p className="text-xs text-text-muted">No trips recorded for this driver.</p>
                )}
              </div>
            </div>
          </div>
        ) : null}
      </DetailModal>
    </div>
  );
}
