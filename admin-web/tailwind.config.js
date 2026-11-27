/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        forest: {
          DEFAULT: '#173D2C',
          50: '#F0F5F2',
          100: '#DCE7E1',
          200: '#B8CFC3',
          300: '#8FB3A0',
          400: '#5A8F73',
          500: '#2D6B4E',
          600: '#23533D',
          700: '#1B4733',
          800: '#173D2C',
          900: '#0F291D',
          950: '#091A12',
          light: '#23533D',
          dark: '#0F291D',
          hover: '#1B4733',
        },
        lime: {
          DEFAULT: '#84CC16',
          accent: '#C8F53E',
          hover: '#BAE632',
          muted: 'rgba(200, 245, 62, 0.15)',
          subtle: '#F4FCE3',
        },
        surface: {
          bg: '#F6F8F5',
          card: '#FFFFFF',
          border: '#E2E8E0',
          subtle: '#EEF2EC',
          hover: '#E8EFE6',
        },
        text: {
          primary: '#111827',
          secondary: '#4B5563',
          muted: '#6B7280',
          inverse: '#FFFFFF',
        },
      },
      boxShadow: {
        'xs': '0 1px 2px 0 rgba(0, 0, 0, 0.04)',
        'card': '0 1px 3px 0 rgba(16, 24, 40, 0.06), 0 1px 2px -1px rgba(16, 24, 40, 0.04)',
        'card-hover': '0 4px 6px -1px rgba(16, 24, 40, 0.08), 0 2px 4px -2px rgba(16, 24, 40, 0.04)',
        'modal': '0 20px 25px -5px rgba(0, 0, 0, 0.1), 0 8px 10px -6px rgba(0, 0, 0, 0.1)',
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', '-apple-system', 'sans-serif'],
      },
    },
  },
  plugins: [],
}
