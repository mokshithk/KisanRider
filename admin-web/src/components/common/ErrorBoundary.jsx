import React, { Component } from 'react';
import { AlertTriangle, RefreshCw, Home } from 'lucide-react';

export default class ErrorBoundary extends Component {
  constructor(props) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error) {
    return { hasError: true, error };
  }

  componentDidCatch(error, errorInfo) {
    console.error('ErrorBoundary caught an error:', error, errorInfo);
  }

  handleReset = () => {
    this.setState({ hasError: false, error: null });
    window.location.reload();
  };

  render() {
    if (this.state.hasError) {
      return (
        <div className="min-h-screen bg-surface-bg flex items-center justify-center p-6">
          <div className="max-w-md w-full bg-white rounded-xl border border-surface-border p-6 shadow-sm text-center">
            <div className="w-12 h-12 rounded-full bg-rose-50 text-rose-600 mx-auto flex items-center justify-center mb-4">
              <AlertTriangle className="w-6 h-6" />
            </div>
            <h2 className="text-lg font-semibold text-text-primary mb-2">Something went wrong</h2>
            <p className="text-xs text-text-secondary mb-6 leading-relaxed">
              An unexpected error occurred while rendering this view. The administrative session remains secure.
            </p>
            <div className="flex items-center justify-center gap-3">
              <button
                onClick={this.handleReset}
                className="inline-flex items-center space-x-2 px-4 py-2 rounded-lg bg-forest text-white text-xs font-medium hover:bg-forest-light transition-colors"
              >
                <RefreshCw className="w-3.5 h-3.5" />
                <span>Reload Page</span>
              </button>
              <a
                href="/"
                className="inline-flex items-center space-x-2 px-4 py-2 rounded-lg border border-surface-border bg-white text-text-primary text-xs font-medium hover:bg-surface-subtle transition-colors"
              >
                <Home className="w-3.5 h-3.5" />
                <span>Dashboard</span>
              </a>
            </div>
          </div>
        </div>
      );
    }
    return this.props.children;
  }
}
