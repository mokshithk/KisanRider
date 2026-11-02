import React, { useState, useEffect } from 'react';
import {
  FileBarChart2,
  Download,
  Calendar,
  Filter,
  RefreshCw,
  FileSpreadsheet,
  CheckCircle2,
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
  const [exporting, setExporting] = useState(false);

  const fetchReport = async () => {
    setLoading(true);
    try {
      const res = await adminService.getReportsSummary(selectedCategory, startDate, endDate);
      setReportData(res.data || []);
      setTotalRecords(res.total_records || 0);
    } catch (err) {
      console.error('Failed to load report summary:', err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchReport();
  }, [selectedCategory]);

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

  // Dynamic columns depending on category
  const getColumns = () => {
    if (selectedCategory === 'farmers') {
      return [
        { header: 'Farmer Name', accessor: 'name' },
        { header: 'Email', accessor: 'email' },
        { header: 'Phone', accessor: 'phone' },
        { header: 'District', accessor: 'district' },
        { header: 'Status', accessor: 'status', render: (r) => <Badge status={r.status} /> },
        { header: 'Registered On', accessor: 'registered_on' },
      ];
    } else if (selectedCategory === 'riders') {
      return [
        { header: 'Rider Name', accessor: 'name' },
        { header: 'Phone', accessor: 'phone' },
        { header: 'Vehicle Specs', accessor: 'vehicle' },
        { header: 'Capacity', accessor: 'capacity_kg', render: (r) => `${r.capacity_kg} kg` },
        { header: 'Duty Status', accessor: 'duty_status', render: (r) => <Badge status={r.duty_status.replace(' ', '_')} text={r.duty_status} /> },
        { header: 'Registered On', accessor: 'registered_on' },
      ];
    } else if (selectedCategory === 'requests') {
      return [
        { header: 'ID', accessor: 'id', render: (r) => `#${r.id}` },
        { header: 'Farmer', accessor: 'farmer' },
        { header: 'Crop', accessor: 'crop' },
        { header: 'Weight', accessor: 'weight_kg', render: (r) => `${r.weight_kg} kg` },
        { header: 'Mandi District', accessor: 'district' },
        { header: 'Status', accessor: 'status', render: (r) => <Badge status={r.status} /> },
        { header: 'Date', accessor: 'date' },
      ];
    } else if (selectedCategory === 'trips') {
      return [
        { header: 'Trip ID', accessor: 'id', render: (r) => `#${r.id}` },
        { header: 'Rider', accessor: 'rider' },
        { header: 'Crop', accessor: 'crop' },
        { header: 'Origin', accessor: 'pickup' },
        { header: 'Status', accessor: 'status', render: (r) => <Badge status={r.status} /> },
        { header: 'Date', accessor: 'date' },
      ];
    } else if (selectedCategory === 'pools') {
      return [
        { header: 'Pool ID', accessor: 'id', render: (r) => `#${r.id}` },
        { header: 'Crop', accessor: 'crop' },
        { header: 'Current Tonnage', accessor: 'current_qty', render: (r) => `${r.current_qty} / ${r.max_qty} kg` },
        { header: 'Dropoff District', accessor: 'district' },
        { header: 'Status', accessor: 'status', render: (r) => <Badge status={r.status} /> },
        { header: 'Created', accessor: 'created_at' },
      ];
    } else {
      // Settlements
      return [
        { header: 'Settlement ID', accessor: 'id', render: (r) => `#${r.id}` },
        { header: 'Crop', accessor: 'crop' },
        { header: 'Gross (₹)', accessor: 'gross_amount', render: (r) => `₹${r.gross_amount}` },
        { header: 'Platform Fee (₹)', accessor: 'platform_fee', render: (r) => `₹${r.platform_fee}` },
        { header: 'Net Payout (₹)', accessor: 'net_payout', render: (r) => `₹${r.net_payout}` },
        { header: 'Status', accessor: 'status', render: (r) => <Badge status={r.status} /> },
        { header: 'Date', accessor: 'date' },
      ];
    }
  };

  return (
    <div className="space-y-6">
      {/* Category Tabs */}
      <div className="flex items-center space-x-1.5 overflow-x-auto pb-1 border-b border-surface-border">
        {categories.map((c) => (
          <button
            key={c.id}
            onClick={() => setSelectedCategory(c.id)}
            className={`px-3.5 py-2 rounded-t-lg text-xs font-semibold whitespace-nowrap transition-colors ${
              selectedCategory === c.id
                ? 'bg-white text-forest border-t-2 border-forest shadow-xs'
                : 'text-text-secondary hover:text-text-primary hover:bg-surface-subtle'
            }`}
          >
            {c.label}
          </button>
        ))}
      </div>

      {/* Filter and Download Bar */}
      <div className="bg-white p-4 rounded-lg border border-surface-border flex flex-col sm:flex-row sm:items-center justify-between gap-3 shadow-xs">
        <div className="flex flex-wrap items-center gap-3">
          <div className="flex items-center space-x-2 text-xs">
            <span className="text-text-secondary font-medium">From:</span>
            <input
              type="date"
              value={startDate}
              onChange={(e) => setStartDate(e.target.value)}
              className="rounded border border-surface-border px-2.5 py-1.5 bg-white text-text-primary focus:outline-none focus:ring-1 focus:ring-forest text-xs"
            />
          </div>
          <div className="flex items-center space-x-2 text-xs">
            <span className="text-text-secondary font-medium">To:</span>
            <input
              type="date"
              value={endDate}
              onChange={(e) => setEndDate(e.target.value)}
              className="rounded border border-surface-border px-2.5 py-1.5 bg-white text-text-primary focus:outline-none focus:ring-1 focus:ring-forest text-xs"
            />
          </div>
          <button
            onClick={fetchReport}
            className="px-3 py-1.5 text-xs font-medium rounded border border-surface-border bg-white text-text-primary hover:bg-surface-subtle transition-colors"
          >
            Filter Dates
          </button>
        </div>

        <div className="flex items-center space-x-3">
          <button
            onClick={handleExportCsv}
            disabled={exporting || reportData.length === 0}
            className="inline-flex items-center space-x-2 px-3.5 py-2 rounded text-xs font-semibold bg-forest text-white hover:bg-forest-light transition-colors disabled:opacity-50 shadow-xs"
          >
            <Download className="w-3.5 h-3.5 text-lime-accent" />
            <span>{exporting ? 'Generating CSV...' : 'Download Official CSV'}</span>
          </button>
        </div>
      </div>

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
        limit={totalRecords}
        totalPages={1}
        isLoading={loading}
        emptyMessage="No historical records match the selected date filter."
      />
    </div>
  );
}
