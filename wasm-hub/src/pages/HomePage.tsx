import { useEffect, useState, useMemo } from 'react';
import { Link } from 'react-router-dom';
import { getPublicWasmFiles, WasmFile } from '../services/firestore';
import { WasmGrid } from '../components/wasm';
import { Button, Input } from '../components/ui';
import { useAuth } from '../contexts/AuthContext';
import styles from './HomePage.module.css';

export function HomePage() {
  const [files, setFiles] = useState<WasmFile[]>([]);
  const [loading, setLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');
  const { user } = useAuth();

  useEffect(() => {
    async function fetchFiles() {
      try {
        const publicFiles = await getPublicWasmFiles();
        setFiles(publicFiles);
      } catch (error) {
        console.error('Error fetching files:', error);
      } finally {
        setLoading(false);
      }
    }
    fetchFiles();
  }, []);

  const filteredFiles = useMemo(() => {
    if (!searchQuery.trim()) return files;

    const query = searchQuery.toLowerCase();
    return files.filter(
      (file) =>
        file.name.toLowerCase().includes(query) ||
        file.fileName.toLowerCase().includes(query) ||
        file.description?.toLowerCase().includes(query) ||
        file.tags?.some((tag) => tag.toLowerCase().includes(query))
    );
  }, [files, searchQuery]);

  return (
    <div className={styles.page}>
      <section className={styles.hero}>
        <h1 className={styles.title}>WASM Hub</h1>
        <p className={styles.subtitle}>
          Share WebAssembly modules for the ROAMR robotics project
        </p>
        <div className={styles.actions}>
          {user ? (
            <Link to="/upload">
              <Button size="lg">Upload WASM</Button>
            </Link>
          ) : (
            <Link to="/login">
              <Button size="lg">Log in</Button>
            </Link>
          )}
        </div>
      </section>

      <section className={styles.browse}>
        <div className={styles.searchBar}>
          <Input
            type="search"
            placeholder="Search by name, description, or tags..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
          />
        </div>

        <WasmGrid
          files={filteredFiles}
          loading={loading}
          emptyMessage={
            searchQuery
              ? 'No files match your search'
              : 'No public WASM files yet. Be the first to upload!'
          }
        />
      </section>
    </div>
  );
}
