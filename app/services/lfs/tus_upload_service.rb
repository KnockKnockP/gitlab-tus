# frozen_string_literal: true

module Lfs
  class TusUploadService
    TUS_VERSION = '1.0.0'
    TUS_CONTENT_TYPE = 'application/offset+octet-stream'

    def initialize(project:, oid:, size:, request:, repository_type:)
      @project = project
      @oid = oid
      @size = size
      @request = request
      @repository_type = repository_type
    end

    def offset
      return size if project_lfs_object_exists?

      reset_upload! if invalid_temp_upload?

      current_temp_offset
    end

    def patch
      with_file_lock do
        current_offset = offset
        upload_offset = request_upload_offset

        unless upload_offset
          next error_response('Missing or invalid Upload-Offset', :invalid_upload_offset, current_offset: current_offset)
        end

        unless request.media_type == TUS_CONTENT_TYPE
          next error_response('Unsupported media type', :unsupported_media_type, current_offset: current_offset)
        end

        unless upload_offset == current_offset
          next error_response('Upload offset does not match', :upload_offset_mismatch, current_offset: current_offset)
        end

        if request_content_length && upload_offset + request_content_length > size
          next error_response('Upload exceeds declared size', :payload_too_large, current_offset: current_offset)
        end

        append_request_body!

        new_offset = current_temp_offset
        if new_offset > size
          File.truncate(temp_path, current_offset)

          next error_response('Upload exceeds declared size', :payload_too_large, current_offset: current_offset)
        end

        next success_response(new_offset) unless new_offset == size

        finalize_upload
      end
    end

    private

    attr_reader :project, :oid, :size, :request, :repository_type

    def project_lfs_object_exists?
      lfs_object = LfsObject.for_oid_and_size(oid, size)

      lfs_object&.file&.exists? && lfs_object.project_allowed_access?(project)
    end

    def invalid_temp_upload?
      current_temp_offset > size
    end

    def current_temp_offset
      return 0 unless File.exist?(temp_path)

      File.size(temp_path)
    end

    def request_upload_offset
      Integer(request.headers['Upload-Offset'])
    rescue ArgumentError, TypeError
      nil
    end

    def request_content_length
      return unless request.headers['Content-Length'].present?

      Integer(request.headers['Content-Length'])
    rescue ArgumentError
      nil
    end

    def append_request_body!
      FileUtils.mkdir_p(temp_dir)
      request.body.binmode if request.body.respond_to?(:binmode)

      File.open(temp_path, 'ab') do |file|
        file.binmode
        IO.copy_stream(request.body, file)
      end
    end

    def finalize_upload
      uploaded_file = UploadedFile.new(
        temp_path,
        filename: File.basename(temp_path),
        sha256: LfsObject.calculate_oid(temp_path)
      )

      response = Lfs::FinalizeUploadService.new(
        oid: oid,
        size: size,
        uploaded_file: uploaded_file,
        project: project,
        repository_type: repository_type
      ).execute

      uploaded_file.close

      return success_response(size, finalized: true) if response.success?

      reset_upload! if response.reason == :invalid_uploaded_file

      ServiceResponse.error(
        message: response.message,
        reason: response.reason,
        payload: { current_offset: current_temp_offset }
      )
    end

    def success_response(offset, finalized: false)
      cleanup_upload! if finalized

      ServiceResponse.success(payload: { current_offset: offset })
    end

    def error_response(message, reason, current_offset:)
      ServiceResponse.error(
        message: message,
        reason: reason,
        payload: { current_offset: current_offset }
      )
    end

    def with_file_lock
      FileUtils.mkdir_p(temp_dir)

      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)

        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    def reset_upload!
      FileUtils.rm_f(temp_path)
    end

    def cleanup_upload!
      FileUtils.rm_f(temp_path)
      FileUtils.rm_f(lock_path)
    end

    def temp_path
      @temp_path ||= File.join(temp_dir, "#{oid}-#{size}")
    end

    def lock_path
      "#{temp_path}.lock"
    end

    def temp_dir
      @temp_dir ||= File.join(LfsObjectUploader.workhorse_local_upload_path, 'tus', project.id.to_s)
    end
  end
end
