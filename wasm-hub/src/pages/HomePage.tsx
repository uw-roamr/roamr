import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { getPublicWasmFiles, WasmFile } from '../services/firestore';
import { WasmGrid } from '../components/wasm';
import { Button } from '../components/ui';
import { useAuth } from '../contexts/AuthContext';
import styles from './HomePage.module.css';

export function HomePage() {
  const [featuredFiles, setFeaturedFiles] = useState<WasmFile[]>([]);
  const [loading, setLoading] = useState(true);
  const { user } = useAuth();

  useEffect(() => {
    async function fetchFeatured() {
      try {
        const files = await getPublicWasmFiles();
        setFeaturedFiles(files.slice(0, 6));
      } catch (error) {
        console.error('Error fetching featured files:', error);
      } finally {
        setLoading(false);
      }
    }
    fetchFeatured();
  }, []);

  return (
    <div className={styles.page}>
      <section className={styles.hero}>
        <h1 className={styles.title}>WASM Hub</h1>
        <p className={styles.subtitle}>
          Share WebAssembly modules across platforms for the ROAMR robotics project
        </p>
        <p className={styles.description}>
          Upload, share, and download WASM files. Enable Windows and Mac developers
          to contribute modules without Apple's ecosystem.
        </p>
        <div className={styles.actions}>
          <Link to="/browse">
            <Button size="lg">Browse Files</Button>
          </Link>
          {user ? (
            <Link to="/upload">
              <Button variant="secondary" size="lg">
                Upload WASM
              </Button>
            </Link>
          ) : (
            <Link to="/register">
              <Button variant="secondary" size="lg">
                Get Started
              </Button>
            </Link>
          )}
        </div>
      </section>

      <section className={styles.features}>
        <div className={styles.feature}>
          <span className={styles.featureIcon}>📦</span>
          <h3>Upload & Share</h3>
          <p>Easily upload .wasm files with drag-and-drop</p>
        </div>
        <div className={styles.feature}>
          <span className={styles.featureIcon}>🔒</span>
          <h3>Privacy Control</h3>
          <p>Set files as public or private</p>
        </div>
        <div className={styles.feature}>
          <span className={styles.featureIcon}>💾</span>
          <h3>Download</h3>
          <p>Download modules directly to your device</p>
        </div>
      </section>

      {(featuredFiles.length > 0 || loading) && (
        <section className={styles.featured}>
          <div className={styles.sectionHeader}>
            <h2>Featured Modules</h2>
            <Link to="/browse" className={styles.viewAll}>
              View all &rarr;
            </Link>
          </div>
          <WasmGrid files={featuredFiles} loading={loading} />
        </section>
      )}
    </div>
  );
}
