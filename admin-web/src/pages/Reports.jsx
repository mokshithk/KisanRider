import React, { useState, useEffect, useRef } from 'react';
import {
  Download,
  AlertCircle,
  RefreshCw,
} from 'lucide-react';
import { adminService } from '../services/adminService';
import DataTable from '../components/common/DataTable';
import Badge from '../components/common/Badge';

const categories = [
  { id: 'farmers', label: 'Farmer Registrations' },
  { id: 'riders', label: 'Rider Registrations' },
  { id: 'requests', label: 'Transport Dispatches' },
  { id: 'trips', label: 'Trip Execution' },
  { id: 'pools', label: 'Farmer Pools' },
  { id: 'settlements', label: 'Financial Settlements' },
];

export default function Reports() {
  const [selectedCategory, setSelectedCategory] = useState('farmers');
  const [startDate, setStartDate] = useState('');
  const [endDate, setEndDate] = useState('');
  const [reportData, setReportData] = useState([]);
  const [totalRecords, setTotalRecords] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [exporting, setExporting] = useState(false);

  // Track active request to prevent race conditions when switching tabs rapidly
  const activeRequestId = useRef(0);

  const fetchReport = async (category = selectedCategory, start = startDate, end = endDate) => {
    const requestId = ++activeRequestId.current;
    setLoading(true);
    setError(null);

    try {
      const res = await adminService.getReportsSummary(category, start, end);
      if (requestId === activeRequestId.current) {
        setReportData(res?.data || []);
        setTotalRecords(res?.total_records || 0);
      }
    } catch (err) {
      if (requestId === activeRequestId.current) {
        console.error('Failed to load report summary:', err);
        setError('Failed to load report records. Please check the network connection or retry.');
        setReportData([]);
        setTotalRecords(0);
      }
    } finally {
      if (requestId === activeRequestId.current) {
        setLoading(false);
      }
    }
  };

  const handleCategoryChange = (newCatId) => {
    if (newCatId === selectedCategory) return;
    // Clear data and set loading synchronously so stale rows are never evaluated against new category column definitions
    setSelectedCategory(newCatId);
    setReportData([]);
    setTotalRecords(0);
    setError(null);
    setLoading(true);
  };

  useEffect(() => {
    fetchReport(selectedCategory, startDate, endDate);
  }, [selectedCategory]);

  const handleFilterClick = () => {
    fetchReport(selectedCategory, startDate, endDate);
  };

  const handleExportCsv = async () => {
    setExporting(true);
    try {
      await adminService.downloadReportCsv(selectedCategory, startDate, endDate);
    } catch (err) {
      console.error('CSV export failed:', err);
      alert('Failed to export CSV report.');
    } finally {
      setExporting(false);
    }
  };

  // Safe dynamic columns depending on category
  const getColumns = () => {
    if (selectedCategory === 'farmers') {
      return [
        { header: 'Farmer Name', accessor: 'name', render: (r) => r.name || '-' },
        { header: 'Email', accessor: 'email', render: (r) => r.email || '-' },
        { header: 'Phone', accessor: 'phone', render: (r) => r.phone || '-' },
        { header: 'District', accessor: 'district', render: (r) => r.district || 'Karnataka' },
        { header: 'Status', accessor: 'status', render: (r) => <Badge status={r.status || 'ACTIVE'} /> },
        { header: 'Registered On', accessor: 'registered_on', render: (r) => r.registered_on || '-' },
      ];
    } else if (selectedCategory === 'riders') {
      return [
        { header: 'Rider Name', accessor: 'name', render: (r) => r.name || '-' },
        { header: 'Phone', accessor: 'phone', render: (r) => r.phone || '-' },
        { header: 'Vehicle Specs', accessor: 'vehicle', render: (r) => r.vehicle || 'Vehicle (N/A)' },
        { header: 'Capacity', accessor: 'capacity_kg', render: (r) => `${r.capacity_kg ?? 0} kg` },
        {
          header: 'Duty Status',
          accessor: 'duty_status',
          render: (r) => (
            <Badge
              status={r.duty_status ? r.duty_status.replace(/\s+/g, '_') : 'OFF_DUTY'}
              text={r.duty_status || 'OFF DUTY'}
            />
          ),
        },
        { header: 'Status', accessor: 'status', render: (r) => <Badge status={r.status || 'ACTIVE'} /> },
        { header: 'Registered On', accessor: 'registered_on', render: (r) => r.registered_on || '-' },
      ];
    } else if (selectedCategory === 'requests') {
      return [
        { header: 'ID', accessor: 'id', render: (r) => `#${r.id || '-'}` },
        { header: 'Farmer', accessor: 'farmer', render: (r) => r.farmer || '-' },
        { header: 'Crop', accessor: 'crop', render: (r) => r.crop || '-' },
        { header: 'Weight', accessor: 'weight_kg', render: (r) => `${r.weight_kg ?? 0} kg` },
        { header: 'Mandi District', accessor: 'district', render: (r) => r.district || '-' },
        { header: 'Status', accessor: 'status', render: (r) => <Badge status={r.status} /> },
        { header: 'Date', accessor: 'date', render: (r) => r.date || '-' },
      ];
    } else if (selectedCategory === 'trips') {
      return [
        { header: 'Trip ID', accessor: 'id', render: (r) => `#${r.id || '-'}` },
        { header: 'Rider', accessor: 'rider', render: (r) => r.rider || '-' },
        { header: 'Crop', accessor: 'crop', render: (r) => r.crop || '-' },
        { header: 'Origin', accessor: 'pickup', render: (r) => r.pickup || '-' },
        { header: 'Status', accessor: 'status', render: (r) => <Badge status={r.status} /> },
        { header: 'Date', accessor: 'date', render: (r) => r.date || '-' },
      ];
    } else if (selectedCategory === 'pools') {
      return [
        { header: 'Pool ID', accessor: 'id', render: (r) => `#${r.id || '-'}` },
        { header: 'Crop', accessor: 'crop', render: (r) => r.crop || '-' },
        {
          header: 'Current Tonnage',
          accessor: 'current_qty',
          render: (r) => `${r.current_qty ?? 0} / ${r.max_qty ?? 0} kg`,
        },
        { header: 'Dropoff District', accessor: 'district', render: (r) => r.district || '-' },
        { header: 'Status', accessor: 'status', render: (r) => <Badge status={r.status} /> },
        { header: 'Created', accessor: 'created_at', render: (r) => r.created_at || '-' },
      ];
    } else {
      // Settlements
      return [
        { header: 'Settlement ID', accessor: 'id', render: (r) => `#${r.id || '-'}` },
        { header: 'Crop', accessor: 'crop', render: (r) => r.crop || '-' },
        { header: 'Gross (₹)', accessor: 'gross_amount', render: (r) => `₹${r.gross_amount ?? 0}` },
        { header: 'Platform Fee (₹)', accessor: 'platform_fee', render: (r) => `₹${r.platform_fee ?? 0}` },
        { header: 'Net Payout (₹)', accessor: 'net_payout', render: (r) => `₹${r.net_payout ?? 0}` },
        { header: 'Status', accessor: 'status', render: (r) => <Badge status={r.status} /> },
        { header: 'Date', accessor: 'date', render: (r) => r.date || '-' },
      ];
    }
  };

  return (
    <div className="space-y-6">
      {/* Category Tabs */}
      <div className="flex items-center space-x-1 overflow-x-auto p-1 bg-surface-subtle/80 rounded-xl border border-surface-border">
        {categories.map((c) => (
          <button
            key={c.id}
            onClick={() => handleCategoryChange(c.id)}
            className={`px-4 py-2 rounded-lg text-xs font-semibold whitespace-nowrap transition-all ${
              selectedCategory === c.id
                ? 'bg-white text-forest shadow-xs'
                : 'text-text-secondary hover:text-text-primary hover:bg-white/60'
            }`}
          >
            {c.label}
          </button>
        ))}
      </div>

      {/* Filter and Download Bar */}
      <div className="bg-white p-4 rounded-xl border border-surface-border flex flex-col sm:flex-row sm:items-center justify-between gap-3 shadow-xs">
        <div className="flex flex-wrap items-center gap-3">
          <div className="flex items-center space-x-2 text-xs">
            <span className="text-text-secondary font-medium">From:</span>
            <input
              type="date"
              value={startDate}
              onChange={(e) => setStartDate(e.target.value)}
              className="rounded-lg border border-surface-border px-3 py-1.5 bg-white text-text-primary focus:outline-none focus:ring-2 focus:ring-forest/20 focus:border-forest text-xs transition-all"
            />
          </div>
          <div className="flex items-center space-x-2 text-xs">
            <span className="text-text-secondary font-medium">To:</span>
            <input
              type="date"
              value={endDate}
              onChange={(e) => setEndDate(e.target.value)}
              className="rounded-lg border border-surface-border px-3 py-1.5 bg-white text-text-primary focus:outline-none focus:ring-2 focus:ring-forest/20 focus:border-forest text-xs transition-all"
            />
          </div>
          <button
            onClick={handleFilterClick}
            disabled={loading}
            className="px-4 py-1.5 text-xs font-semibold rounded-lg border border-surface-border bg-white text-text-primary hover:bg-surface-subtle transition-colors shadow-xs disabled:opacity-50"
          >
            Filter Dates
          </button>
        </div>

        <div className="flex items-center space-x-3">
          <button
            onClick={handleExportCsv}
            disabled={exporting || reportData.length === 0}
            className="inline-flex items-center space-x-2 px-4 py-2 rounded-lg text-xs font-semibold bg-forest text-white hover:bg-forest-light transition-colors disabled:opacity-50 shadow-xs"
          >
            <Download className="w-3.5 h-3.5 text-lime-accent" />
            <span>{exporting ? 'Generating CSV...' : 'Download Official CSV'}</span>
          </button>
        </div>
      </div>

      {/* Error Notice */}
      {error && (
        <div className="p-4 rounded-xl bg-rose-50 border border-rose-200/80 text-rose-800 text-xs flex items-center justify-between shadow-xs">
          <div className="flex items-center space-x-2">
            <AlertCircle className="w-4 h-4 flex-shrink-0 text-rose-600" />
            <span>{error}</span>
          </div>
          <button
            onClick={() => fetchReport()}
            className="font-medium underline hover:text-rose-950 ml-3"
          >
            Retry
          </button>
        </div>
      )}

      {/* Record Counter */}
      <div className="flex items-center justify-between text-xs text-text-secondary px-1">
        <span>
          Showing actual queried database rows for{' '}
          <strong className="text-text-primary">
            {categories.find((c) => c.id === selectedCategory)?.label}
          </strong>
        </span>
        <span className="font-semibold text-text-primary">{totalRecords} Total Records</span>
      </div>

      {/* Table */}
      <DataTable
        columns={getColumns()}
        data={reportData}
        total={totalRecords}
        page={1}
        limit={totalRecords || 10}
        totalPages={1}
        isLoading={loading}
        emptyMessage="No historical records match the selected date filter."
      />
    </div>
  );
}
