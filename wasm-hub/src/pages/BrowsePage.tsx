import { useEffect, useState, useMemo } from 'react';
import { getPublicWasmFiles, WasmFile } from '../services/firestore';
import { WasmGrid } from '../components/wasm';
import { Input } from '../components/ui';
import styles from './BrowsePage.module.css';

export function BrowsePage() {
  const [files, setFiles] = useState<WasmFile[]>([]);
  const [loading, setLoading] = useState(true);
  const [searchQuery, setSearchQuery] = useState('');

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
      <div className={styles.header}>
        <h1 className={styles.title}>Browse WASM Files</h1>
        <p className={styles.subtitle}>
          Discover public WebAssembly modules shared by the community
        </p>
      </div>

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
    </div>
  );
}
