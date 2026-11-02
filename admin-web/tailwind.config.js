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
          light: '#23533D',
          dark: '#0F291D',
          hover: '#1B4733',
        },
        lime: {
          accent: '#C8F53E',
          hover: '#BAE632',
          muted: 'rgba(200, 245, 62, 0.15)',
        },
        surface: {
          bg: '#F4F7F3',
          card: '#FFFFFF',
          border: '#E4EAE3',
          subtle: '#EEF3EC',
        },
        text: {
          primary: '#18231D',
          secondary: '#778179',
          muted: '#9DA69F',
        },
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', '-apple-system', 'sans-serif'],
      },
    },
  },
  plugins: [],
}
