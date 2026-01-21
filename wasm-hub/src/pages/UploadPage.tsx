import { useState, FormEvent } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../contexts/AuthContext';
import { createWasmFile, incrementUserUploadCount } from '../services/firestore';
import { uploadWasmFile, UploadProgress } from '../services/storage';
import { WasmUploader } from '../components/wasm';
import { Button, Input } from '../components/ui';
import { useToast } from '../components/ui/Toast';
import styles from './UploadPage.module.css';

export function UploadPage() {
  const { user } = useAuth();
  const navigate = useNavigate();
  const { showToast } = useToast();

  const [file, setFile] = useState<File | null>(null);
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [tags, setTags] = useState('');
  const [isPublic, setIsPublic] = useState(true);
  const [uploading, setUploading] = useState(false);
  const [progress, setProgress] = useState<UploadProgress | null>(null);

  const handleFileSelect = (selectedFile: File) => {
    setFile(selectedFile);
    if (!name) {
      setName(selectedFile.name.replace('.wasm', ''));
    }
  };

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();

    if (!file || !user) {
      showToast('Please select a file', 'error');
      return;
    }

    if (!name.trim()) {
      showToast('Please enter a name', 'error');
      return;
    }

    setUploading(true);

    try {
      const fileId = crypto.randomUUID();

      const { url, path } = await uploadWasmFile(
        file,
        user.uid,
        fileId,
        setProgress
      );

      await createWasmFile({
        name: name.trim(),
        fileName: file.name,
        description: description.trim(),
        uploaderId: user.uid,
        uploaderName: user.displayName || user.email || 'Unknown',
        isPublic,
        storageUrl: url,
        storagePath: path,
        fileSize: file.size,
        tags: tags
          .split(',')
          .map((t) => t.trim().toLowerCase())
          .filter((t) => t.length > 0),
      });

      await incrementUserUploadCount(user.uid);

      showToast('File uploaded successfully!', 'success');
      navigate('/dashboard');
    } catch (error) {
      console.error('Upload error:', error);
      showToast('Failed to upload file', 'error');
    } finally {
      setUploading(false);
      setProgress(null);
    }
  };

  return (
    <div className={styles.page}>
      <div className={styles.header}>
        <h1 className={styles.title}>Upload WASM File</h1>
        <p className={styles.subtitle}>
          Share your WebAssembly module with the community
        </p>
      </div>

      <form className={styles.form} onSubmit={handleSubmit}>
        <WasmUploader
          onFileSelect={handleFileSelect}
          progress={progress}
          uploading={uploading}
        />

        <Input
          label="Name"
          placeholder="My Awesome Module"
          value={name}
          onChange={(e) => setName(e.target.value)}
          required
          disabled={uploading}
        />

        <div className={styles.field}>
          <label className={styles.label}>Description</label>
          <textarea
            className={styles.textarea}
            placeholder="Describe what this module does..."
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            rows={3}
            disabled={uploading}
          />
        </div>

        <Input
          label="Tags (comma-separated)"
          placeholder="robotics, controller, sensor"
          value={tags}
          onChange={(e) => setTags(e.target.value)}
          disabled={uploading}
        />

        <div className={styles.field}>
          <label className={styles.checkboxLabel}>
            <input
              type="checkbox"
              checked={isPublic}
              onChange={(e) => setIsPublic(e.target.checked)}
              disabled={uploading}
            />
            <span>Make this file public</span>
          </label>
          <p className={styles.hint}>
            Public files can be viewed and downloaded by anyone
          </p>
        </div>

        <Button type="submit" loading={uploading} disabled={!file}>
          {uploading ? 'Uploading...' : 'Upload File'}
        </Button>
      </form>
    </div>
  );
}
